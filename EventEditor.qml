import QtQuick
import qs.Commons

// In-window card to add or edit one Almanac event.
Item {
  id: root
  property var host: null
  property var event: null

  readonly property color fg: host ? host.contentForeground : Color.foreground
  readonly property string fontFamily: host ? host.contentFontFamily : Style.font.family
  readonly property bool isNew: !event || !event.id
  readonly property bool canWrite: host && host.canEditEvent(event)
  readonly property bool repeats: !!(event && event.repeats)
  // Delete on a repeating event asks: this date, or all dates.
  property bool askDelete: false

  visible: event !== null
  z: 40

  function close() {
    if (host) host.closeEventEditor()
  }

  onEventChanged: fill()
  onVisibleChanged: if (visible) fill()

  function fill() {
    askDelete = false
    if (!event) return
    titleField.text = event.title || ""
    dateField.text = event.dateKey || (host ? host.selectedKey : "")
    startField.text = event.allDay || !event.start ? "09:00" : event.start
    endField.text = event.allDay || !event.end ? "10:00" : event.end
    allDayBox.checked = !!(event.allDay || !event.start)
  }

  function draft() {
    return {
      uid: host ? host.eventUidOf(event) : "",
      title: titleField.text,
      dateKey: dateField.text,
      start: startField.text,
      end: endField.text,
      allDay: allDayBox.checked
    }
  }

  Rectangle {
    anchors.fill: parent
    color: Qt.rgba(0, 0, 0, 0.46)
    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }
  }

  Rectangle {
    id: card
    anchors.centerIn: parent
    width: Math.min(Style.space(420), parent.width - Style.space(72))
    implicitHeight: cardCol.implicitHeight + Style.space(40)
    height: implicitHeight
    color: Color.background
    border.width: Style.spacing.hairline
    border.color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.18)

    MouseArea { anchors.fill: parent }

    Column {
      id: cardCol
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.leftMargin: Style.space(24)
      anchors.rightMargin: Style.space(24)
      anchors.topMargin: Style.space(20)
      spacing: Style.space(14)

      Text {
        text: root.isNew ? "New event" : "Edit event"
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.heading
        font.bold: true
      }

      Column {
        width: parent.width
        spacing: Style.space(6)
        Text {
          text: "TITLE"
          color: Qt.darker(root.fg, 1.5)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.letterSpacing: 1.4
        }
        Rectangle {
          width: parent.width
          height: Style.space(36)
          color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08)
          TextInput {
            id: titleField
            anchors.fill: parent
            anchors.leftMargin: Style.space(10)
            anchors.rightMargin: Style.space(10)
            verticalAlignment: TextInput.AlignVCenter
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            selectByMouse: true
            clip: true
            enabled: root.canWrite
            onAccepted: if (root.host) root.host.saveEvent(root.draft())
          }
        }
      }

      Column {
        width: parent.width
        spacing: Style.space(6)
        Text {
          text: "DATE"
          color: Qt.darker(root.fg, 1.5)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.letterSpacing: 1.4
        }
        Rectangle {
          width: parent.width
          height: Style.space(36)
          color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08)
          TextInput {
            id: dateField
            anchors.fill: parent
            anchors.leftMargin: Style.space(10)
            anchors.rightMargin: Style.space(10)
            verticalAlignment: TextInput.AlignVCenter
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            selectByMouse: true
            clip: true
            enabled: root.canWrite
          }
        }
      }

      Text {
        text: allDayBox.checked ? "All day" : "Timed"
        color: allDayMouse.containsMouse ? Style.hoverStateColor(root.fg, Color.accent) : root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        MouseArea {
          id: allDayMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          enabled: root.canWrite
          onClicked: allDayBox.checked = !allDayBox.checked
        }
      }
      Item {
        id: allDayBox
        property bool checked: false
        width: 0
        height: 0
      }

      Row {
        visible: !allDayBox.checked
        width: parent.width
        spacing: Style.space(12)

        Column {
          width: (parent.width - Style.space(12)) / 2
          spacing: Style.space(6)
          Text {
            text: "START"
            color: Qt.darker(root.fg, 1.5)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.letterSpacing: 1.4
          }
          Rectangle {
            width: parent.width
            height: Style.space(36)
            color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08)
            TextInput {
              id: startField
              anchors.fill: parent
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              verticalAlignment: TextInput.AlignVCenter
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              selectByMouse: true
              enabled: root.canWrite
            }
          }
        }

        Column {
          width: (parent.width - Style.space(12)) / 2
          spacing: Style.space(6)
          Text {
            text: "END"
            color: Qt.darker(root.fg, 1.5)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.letterSpacing: 1.4
          }
          Rectangle {
            width: parent.width
            height: Style.space(36)
            color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08)
            TextInput {
              id: endField
              anchors.fill: parent
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              verticalAlignment: TextInput.AlignVCenter
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              selectByMouse: true
              enabled: root.canWrite
            }
          }
        }
      }

      Text {
        visible: host && host.eventError !== ""
        width: parent.width
        wrapMode: Text.Wrap
        text: host ? host.eventError : ""
        color: Color.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      Row {
        visible: root.askDelete
        spacing: Style.space(16)

        Text {
          text: "Delete"
          color: Qt.darker(root.fg, 1.5)
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          topPadding: Style.space(4)
          bottomPadding: Style.space(4)
        }

        Text {
          text: host && host.eventSaving ? "Deleting" : "This date"
          color: oneMouse.containsMouse ? Color.urgent : root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          topPadding: Style.space(4)
          bottomPadding: Style.space(4)
          MouseArea {
            id: oneMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: if (root.host && !root.host.eventSaving) root.host.deleteEvent(root.draft(), false)
          }
        }

        Text {
          text: "All dates"
          color: allMouse.containsMouse ? Color.urgent : Qt.darker(root.fg, 1.35)
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          topPadding: Style.space(4)
          bottomPadding: Style.space(4)
          MouseArea {
            id: allMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: if (root.host && !root.host.eventSaving) root.host.deleteEvent(root.draft(), true)
          }
        }

        Text {
          text: "Back"
          color: backMouse.containsMouse
            ? Style.hoverStateColor(root.fg, Color.accent)
            : Qt.darker(root.fg, 1.45)
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          topPadding: Style.space(4)
          bottomPadding: Style.space(4)
          MouseArea {
            id: backMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.askDelete = false
          }
        }
      }

      Row {
        visible: !root.askDelete
        spacing: Style.space(16)

        Text {
          visible: root.canWrite
          text: host && host.eventSaving ? "Saving" : "Save"
          color: saveMouse.containsMouse
            ? Style.hoverStateColor(root.fg, Color.accent)
            : root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          topPadding: Style.space(4)
          bottomPadding: Style.space(4)
          MouseArea {
            id: saveMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: if (root.host && !root.host.eventSaving) root.host.saveEvent(root.draft())
          }
        }

        Text {
          visible: root.canWrite && !root.isNew
          text: "Delete"
          color: delMouse.containsMouse ? Color.urgent : Qt.darker(root.fg, 1.35)
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          topPadding: Style.space(4)
          bottomPadding: Style.space(4)
          MouseArea {
            id: delMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              if (!root.host || root.host.eventSaving) return
              if (root.repeats) root.askDelete = true
              else root.host.deleteEvent(root.draft(), true)
            }
          }
        }

        Text {
          text: "Cancel"
          color: cancelMouse.containsMouse
            ? Style.hoverStateColor(root.fg, Color.accent)
            : Qt.darker(root.fg, 1.45)
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          topPadding: Style.space(4)
          bottomPadding: Style.space(4)
          MouseArea {
            id: cancelMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.close()
          }
        }
      }
    }
  }
}
