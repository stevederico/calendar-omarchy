import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Agent Cloud Calendar mark in the bar. Click opens the window app.
BarWidget {
  id: root
  moduleName: "sd.calendar"

  readonly property bool opened: false

  function openWindow() {
    Quickshell.execDetached(["omarchy-shell", "-q", "shell", "summon", "sd.calendar"])
  }

  function open() { root.openWindow() }
  function close() {}
  function toggle() { root.openWindow() }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  IpcHandler {
    target: "sd.calendar"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
  }

  IpcHandler {
    target: "agentcloud-calendar"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
  }

  IpcHandler {
    target: "calendar"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰃭"
    tooltipText: "Agent Cloud Calendar"
    onPressed: function (b) {
      if (b === Qt.LeftButton || b === Qt.RightButton) root.openWindow()
    }
  }
}
