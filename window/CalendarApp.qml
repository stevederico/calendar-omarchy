import QtQuick
import Quickshell
import qs.Commons

// Normal Hyprland-tiled window. Summon with:
//   omarchy-shell shell summon sd.calendar
Item {
  id: root

  property var shell: null
  property var manifest: null
  property bool closingFromHost: false
  readonly property bool opened: window.visible
  readonly property var view: viewLoader.item
  property string keepMode: "month"

  function open(payloadJson) {
    closingFromHost = false
    window.visible = true
  }

  function close() {
    closingFromHost = true
    window.visible = false
    closingFromHost = false
  }

  function requestClose() {
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "sd.calendar")
    else
      root.close()
  }

  function injectView() {
    if (!view) return
    view.closeRequested.connect(root.requestClose)
  }

  FloatingWindow {
    id: window
    title: "Agent Cloud Calendar"
    visible: false
    color: Color.background
    implicitWidth: 1400
    implicitHeight: 1600
    minimumSize: Qt.size(Style.space(520), Style.space(640))

    onVisibleChanged: {
      if (visible) {
        if (view && view.refresh) view.refresh()
        Qt.callLater(function () { if (view) view.forceActiveFocus() })
      } else if (!root.closingFromHost && root.shell && typeof root.shell.hide === "function") {
        root.shell.hide((root.manifest && root.manifest.id) || "sd.calendar")
      }
    }

    // Bind to the real window size. anchors.fill on a Loader does not
    // follow Hyprland tile resize — the scene stayed implicit-sized.
    Rectangle {
      width: window.width
      height: window.height
      color: Color.background
    }

    Loader {
      id: viewLoader
      readonly property int insetX: Style.space(16)
      readonly property int insetTop: Style.space(12)
      readonly property int insetBottom: Style.space(12)
      x: insetX
      y: insetTop
      width: Math.max(0, window.width - insetX * 2)
      height: Math.max(0, window.height - insetTop - insetBottom)
      active: window.visible
      source: Qt.resolvedUrl("../CalendarView.qml")
      onLoaded: {
        item.width = Qt.binding(function () { return viewLoader.width })
        item.height = Qt.binding(function () { return viewLoader.height })
        item.live = true
        item.viewMode = root.keepMode
        item.viewModeChanged.connect(function () { root.keepMode = item.viewMode })
        root.injectView()
        if (item.refresh) item.refresh()
        Qt.callLater(function () { if (viewLoader.item) viewLoader.item.forceActiveFocus() })
      }
    }
  }
}
