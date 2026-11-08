import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "Cloud.js" as Cloud

// Month grid + subscribed calendars. Chips in cells like macOS Calendar.
Item {
  id: root
  focus: true

  property var bar: null
  signal closeRequested()

  property date today: new Date()
  readonly property string todayKey: Model.keyForDate(today)
  property string selectedKey: todayKey
  property int viewYear: today.getFullYear()
  property int viewMonth: today.getMonth()
  property bool live: true
  property string viewMode: "month"
  readonly property var viewModes: [
    { id: "day", label: "Day" },
    { id: "week", label: "Week" },
    { id: "month", label: "Month" },
    { id: "year", label: "Year" }
  ]

  readonly property date viewDate: new Date(viewYear, viewMonth, 1)
  readonly property bool viewingCurrentMonth: viewYear === today.getFullYear() && viewMonth === today.getMonth()
  readonly property var weekDays: viewMode === "week" ? Model.weekDaysFromKey(selectedKey, weekStart, todayKey) : []
  readonly property var yearMonths: viewMode === "year" ? Model.yearMonths(viewYear, weekStart, todayKey) : []
  readonly property string headerTitle: {
    if (viewMode === "day") {
      var parsed = Model.parseDateKey(selectedKey)
      if (!parsed) return ""
      return Qt.formatDate(new Date(parsed.year, parsed.month, parsed.day), "dddd, MMMM d, yyyy")
    }
    if (viewMode === "week") return Model.formatWeekTitle(weekDays)
    if (viewMode === "year") return String(viewYear)
    return Qt.formatDate(viewDate, "MMMM yyyy")
  }
  readonly property bool viewingToday: {
    if (viewMode === "day") return selectedKey === todayKey
    if (viewMode === "week") {
      for (var i = 0; i < weekDays.length; i++) if (weekDays[i].key === todayKey) return true
      return false
    }
    if (viewMode === "year") return viewYear === today.getFullYear()
    return viewingCurrentMonth
  }
  readonly property string stepLabel: viewMode === "day" ? "day" : viewMode === "week" ? "week" : viewMode === "year" ? "year" : "month"
  readonly property real yearDone: Model.yearProgress(today.getFullYear(), today.getMonth(), today.getDate())
  readonly property int yearDonePercent: Model.yearProgressPercent(today.getFullYear(), today.getMonth(), today.getDate())
  readonly property int weekStart: Model.normalizedWeekStart(null, Qt.locale().firstDayOfWeek)
  readonly property var weekdays: Model.weekdayOrder(weekStart)
  readonly property string selectedLabel: Model.formatSelectedDateLabel(selectedKey, todayKey)
  property var eventsByDate: ({})
  property var calendars: []
  readonly property var selectedEvents: Model.eventsForDay(eventsByDate, selectedKey)
  readonly property string eventsPath: (Quickshell.env("XDG_STATE_HOME") || ((Quickshell.env("HOME") || "") + "/.local/state")) + "/omarchy/sd-calendar.json"
  readonly property string pluginDir: {
    var url = String(Qt.resolvedUrl("."))
    if (url.indexOf("file://") === 0) url = url.slice(7)
    if (url.length > 1 && url.charAt(url.length - 1) === "/") url = url.slice(0, -1)
    return url
  }
  readonly property string calendarBin: pluginDir + "/bin/sd-calendar"

  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property var labelLocale: Qt.locale("en_US")

  property bool sidebarCollapsed: false
  readonly property int sidebarWidth: Style.space(160)
  readonly property int sidebarRailWidth: Style.space(36)
  readonly property int cellSpacing: Style.space(6)
  readonly property int weekColumnWidth: Style.space(36)
  readonly property int gutterWidth: Style.space(20)
  readonly property int headerHeight: Style.space(32)

  property bool busy: false
  property bool addingCalendar: false
  property var detailCalendar: null
  property string statusText: ""
  property var calQueue: []
  property string calKind: ""
  property var hostedCalendars: []
  property string hostedCalendarId: hostedCalendars.length ? hostedCalendars[0].id : ""
  property var editingEvent: null
  property string eventError: ""
  property bool eventSaving: false
  property int eventToken: 0
  property var pendingEvent: null
  readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || ((Quickshell.env("HOME") || "") + "/.config")
  readonly property string calendarsPath: configHome + "/agentcloud/hosted-calendars.json"
  // Installs from before the Agent Cloud rename keep their key here. Read only when calendarsPath is missing.
  readonly property string legacyCalendarsPath: configHome + "/almanac/hosted-calendars.json"
  property bool calendarsPrimary: false
  property var legacyHostedCalendars: []
  // Plaintext request bodies: the private runtime dir, else a private cache dir. Removed after each write.
  readonly property string cloudBodyDir: Quickshell.env("XDG_RUNTIME_DIR") || ((Quickshell.env("XDG_CACHE_HOME") || ((Quickshell.env("HOME") || "") + "/.cache")) + "/agentcloud-calendar")
  property string syncNotice: ""
  // Request body per write token, removed when that write finishes (even if the editor closed).
  property var bodyPaths: ({})

  function refresh() {
    var now = new Date()
    if (Model.keyForDate(now) !== todayKey) today = now
  }

  function goToToday() {
    viewYear = today.getFullYear()
    viewMonth = today.getMonth()
    selectedKey = todayKey
  }

  function moveMonth(delta) {
    var next = Model.stepMonth(viewYear, viewMonth, delta)
    viewYear = next.year
    viewMonth = next.month
  }

  function moveYear(delta) {
    viewYear += delta
  }

  function moveStep(delta) {
    if (viewMode === "month") {
      moveMonth(delta)
      return
    }
    if (viewMode === "year") {
      moveYear(delta)
      return
    }
    var next = Model.addDaysFromKey(selectedKey, viewMode === "week" ? delta * 7 : delta)
    if (!next) return
    selectedKey = next.key
    viewYear = next.year
    viewMonth = next.month
  }

  function selectDay(day) {
    if (!day || !day.key) return
    selectedKey = day.key
    if (day.year !== viewYear || day.month !== viewMonth) {
      viewYear = day.year
      viewMonth = day.month
    }
  }

  function applyEvents(text) {
    var parsed = Model.parseEventsFile(text)
    eventsByDate = parsed.eventsByDate
    for (var c = 0; c < parsed.calendars.length; c++) {
      var cal = parsed.calendars[c]
      if (cal && cal.name === "Almanac") cal.name = Cloud.PRODUCT
    }
    calendars = parsed.calendars
    if (detailCalendar && detailCalendar.id) {
      var id = detailCalendar.id
      var next = null
      for (var i = 0; i < calendars.length; i++) {
        if (calendars[i] && calendars[i].id === id) {
          next = calendars[i]
          break
        }
      }
      detailCalendar = next
    }
  }

  onLiveChanged: if (live) eventsFile.reload()

  readonly property var weekdayLabels: {
    var out = []
    for (var i = 0; i < weekdays.length; i++)
      out.push(String(labelLocale.dayName(weekdays[i], Locale.ShortFormat)).toUpperCase())
    return out
  }

  function weekdayLabel(weekday) {
    var i = weekdays.indexOf(weekday)
    return i >= 0 ? weekdayLabels[i] : String(labelLocale.dayName(weekday, Locale.ShortFormat)).toUpperCase()
  }

  function cellForeground(day) {
    if (day.today || day.key === selectedKey) return contentForeground
    if (!day.inMonth) return Qt.darker(contentForeground, 2.2)
    if (day.weekend) return Qt.darker(contentForeground, 1.45)
    return contentForeground
  }

  function eventColor(event) {
    if (event && event.color) return event.color
    return Style.selectedStateColor(contentForeground, Color.accent)
  }

  function chipLabel(event) {
    if (!event) return ""
    if (event.allDay || !event.start) return event.title
    return event.start + "  " + event.title
  }

  function dayEvents(key) {
    return Model.eventsForDay(eventsByDate, key)
  }

  function eventUidOf(event) {
    return Cloud.eventUid(event)
  }

  function canEditEvent(event) {
    if (!hostedCalendarId) return false
    if (!event || !event.id) return true
    return Cloud.isWritable(event, calendars)
  }

  function openNewEvent() {
    eventError = ""
    editingEvent = {
      id: "",
      calendarId: "cloud",
      dateKey: selectedKey,
      title: "",
      start: "09:00",
      end: "10:00",
      allDay: false
    }
  }

  function openEvent(event) {
    if (!event) return
    eventError = ""
    editingEvent = event
  }

  function closeEventEditor() {
    editingEvent = null
    eventError = ""
    eventSaving = false
    pendingEvent = null
  }

  function saveEvent(draft) {
    if (eventSaving) return
    if (!hostedCalendarId) {
      eventError = "No Agent Cloud calendar"
      return
    }
    var built = Cloud.buildEventBody(draft)
    if (built.error) {
      eventError = built.error
      return
    }
    var body = built.body
    var copy = null
    if (body.uid) {
      // Saved as a new event if the server refuses this edit.
      copy = Cloud.conflictCopy(body)
      // Only the title changed: leave the times alone, so a repeating series stays put.
      if (editingEvent && Cloud.sameWhen(editingEvent, draft)) body = { uid: body.uid, summary: body.summary }
    }
    writeEvent(body, body.uid ? eventRevOf(editingEvent) : "", copy)
  }

  // copy: the body to save as a new event on a conflict, or null.
  function writeEvent(body, rev, copy) {
    eventSaving = true
    eventError = ""
    eventToken += 1
    var path = cloudBodyDir + "/agentcloud-calendar-body-" + eventToken + ".json"
    pendingEvent = { op: "post", token: eventToken, path: path, rev: rev, copy: copy }
    var paths = Object.assign({}, bodyPaths)
    paths[eventToken] = path
    bodyPaths = paths
    cloudBodyFile.path = path
    var text = JSON.stringify(body) + "\n"
    var token = eventToken
    Qt.callLater(function () {
      if (root.pendingEvent && root.pendingEvent.token === token) cloudBodyFile.setText(text)
    })
  }

  // The Cloud rev the store kept for this event (from X-CLOUD-REV), or "".
  function eventRevOf(event) {
    return event && event.rev ? String(event.rev) : ""
  }

  // Removes request bodies after each write. Paths queue while one rm runs.
  property var rmPaths: []

  function removeBodyFile(path) {
    if (!path) return
    rmPaths = rmPaths.concat([path])
    if (!rmProc.running) runRemove()
  }

  function runRemove() {
    if (!rmPaths.length) return
    rmProc.command = ["rm", "-f"].concat(rmPaths)
    rmPaths = []
    rmProc.running = true
  }

  // allDates: delete the whole series. Otherwise a repeating event skips only
  // the date it was opened on (an exdate); a single event is deleted.
  function deleteEvent(draft, allDates) {
    var uid = Cloud.eventUid(draft) || (editingEvent ? Cloud.eventUid(editingEvent) : "")
    if (!uid || !hostedCalendarId || eventSaving) return
    eventSaving = true
    eventError = ""
    eventToken += 1
    var rev = eventRevOf(editingEvent)
    if (Cloud.repeats(editingEvent) && !allDates) {
      var when = Cloud.occurrenceOf(editingEvent)
      pendingEvent = { op: "skip", token: eventToken }
      cloudRemote.skip(hostedCalendarId, uid, when.date, when.time, eventToken, rev)
      return
    }
    pendingEvent = { op: "delete", token: eventToken }
    cloudRemote.remove(hostedCalendarId, uid, eventToken, rev)
  }

  function onCloudFinished(op, ok, body, token) {
    if (bodyPaths[token]) {
      removeBodyFile(bodyPaths[token])
      var paths = Object.assign({}, bodyPaths)
      delete paths[token]
      bodyPaths = paths
    }
    if (!pendingEvent || token !== pendingEvent.token) return
    var job = pendingEvent
    pendingEvent = null
    eventSaving = false
    if (!ok && Cloud.isConflict(body) && job.copy) {
      // Changed or deleted elsewhere: keep the server's event and save ours as a new one.
      syncNotice = "Event changed elsewhere, saved a copy"
      writeEvent(job.copy, "", null)
      return
    }
    if (!ok && Cloud.isConflict(body)) {
      // Changed elsewhere since the last sync: reload and say so.
      closeEventEditor()
      syncNotice = "Event changed elsewhere, reloaded"
      runCal(["sync"])
      return
    }
    if (!ok) {
      eventError = Cloud.errorMessage(body)
      return
    }
    closeEventEditor()
    runCal(["sync"])
  }

  function runCal(args) {
    if (root.busy) {
      calQueue.push(args)
      return
    }
    root.busy = true
    root.calKind = args[0] || ""
    root.statusText = ""
    calProc.command = [root.calendarBin].concat(args)
    calProc.running = true
  }

  function setSidebarCollapsed(collapsed) {
    if (collapsed && root.addingCalendar) root.closeAddForm()
    root.sidebarCollapsed = collapsed
  }

  function openAddForm() {
    root.sidebarCollapsed = false
    root.addingCalendar = true
    root.statusText = ""
    Qt.callLater(function () { urlField.forceActiveFocus() })
  }

  function closeAddForm() {
    root.addingCalendar = false
    nameField.text = ""
    urlField.text = ""
    root.statusText = ""
  }

  function subscribeFromFields() {
    var url = String(urlField.text || "").replace(/^\s+|\s+$/g, "")
    var name = String(nameField.text || "").replace(/^\s+|\s+$/g, "")
    if (!url) {
      root.statusText = "Paste an ICS URL"
      return
    }
    if (!name) name = Cloud.isCloudUrl(url) ? Cloud.PRODUCT : "Calendar"
    root.runCal(["subscribe", name, url])
  }

  Keys.onPressed: function (event) {
    if (event.key === Qt.Key_Escape) {
      if (root.editingEvent) root.closeEventEditor()
      else if (root.detailCalendar) root.detailCalendar = null
      else if (root.addingCalendar) root.closeAddForm()
      else root.closeRequested()
      event.accepted = true
    } else if (!root.editingEvent && (event.key === Qt.Key_N || event.text === "n" || event.text === "N")) {
      root.openNewEvent()
      event.accepted = true
    } else if (event.key === Qt.Key_Left || event.text === "[") {
      root.moveStep(-1)
      event.accepted = true
    } else if (event.key === Qt.Key_Right || event.text === "]") {
      root.moveStep(1)
      event.accepted = true
    } else if (event.key === Qt.Key_Up || event.text === "{") {
      root.moveYear(-1)
      event.accepted = true
    } else if (event.key === Qt.Key_Down || event.text === "}") {
      root.moveYear(1)
      event.accepted = true
    } else if (event.text === "1") {
      root.viewMode = "day"
      event.accepted = true
    } else if (event.text === "2") {
      root.viewMode = "week"
      event.accepted = true
    } else if (event.text === "3") {
      root.viewMode = "month"
      event.accepted = true
    } else if (event.text === "4") {
      root.viewMode = "year"
      event.accepted = true
    } else if (event.key === Qt.Key_T || event.text === "t" || event.text === "T") {
      root.goToToday()
      event.accepted = true
    } else if (event.key === Qt.Key_R && (event.modifiers & Qt.ControlModifier)) {
      root.runCal(["sync"])
      event.accepted = true
    }
  }

  FileView {
    id: eventsFile
    path: root.eventsPath
    watchChanges: root.live
    atomicWrites: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.applyEvents(text())
    onLoadFailed: root.applyEvents("")
  }

  // Same choice as cloud-lib.sh: the Agent Cloud file when it exists, else the old almanac one.
  FileView {
    id: hostedFile
    path: root.calendarsPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      root.calendarsPrimary = true
      root.hostedCalendars = Cloud.parseCalendars(text())
    }
    onLoadFailed: {
      root.calendarsPrimary = false
      root.hostedCalendars = root.legacyHostedCalendars
    }
  }

  FileView {
    id: legacyHostedFile
    path: root.legacyCalendarsPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      root.legacyHostedCalendars = Cloud.parseCalendars(text())
      if (!root.calendarsPrimary) root.hostedCalendars = root.legacyHostedCalendars
    }
    onLoadFailed: {
      root.legacyHostedCalendars = []
      if (!root.calendarsPrimary) root.hostedCalendars = []
    }
  }

  FileView {
    id: cloudBodyFile
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onSaved: {
      if (root.pendingEvent && root.pendingEvent.op === "post" && root.pendingEvent.path === cloudBodyFile.path)
        cloudRemote.post(root.hostedCalendarId, root.pendingEvent.path, root.pendingEvent.token, root.pendingEvent.rev)
      else
        root.removeBodyFile(cloudBodyFile.path)
    }
    onSaveFailed: {
      if (root.pendingEvent) root.removeBodyFile(root.pendingEvent.path || "")
      root.pendingEvent = null
      root.eventSaving = false
      root.eventError = "Could not write Agent Cloud request"
    }
  }

  CloudRemote {
    id: cloudRemote
    onFinished: function (op, ok, body, token) {
      root.onCloudFinished(op, ok, body, token)
    }
  }

  Process {
    id: calProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var err = String(text || "").replace(/^\s+|\s+$/g, "")
        if (err) root.statusText = err.replace(/^sd-calendar:\s*/, "")
      }
    }
    onExited: function (code) {
      root.busy = false
      if (root.syncNotice && root.calKind === "sync") {
        root.statusText = root.syncNotice
        root.syncNotice = ""
      }
      if (code === 0) {
        if (root.addingCalendar) root.closeAddForm()
        else if (root.calKind !== "unsubscribe" && root.calKind !== "rename" && root.calKind !== "color" && root.calKind !== "toggle" && !root.statusText)
          root.statusText = "Synced"
      }
      eventsFile.reload()
      if (root.calQueue.length) {
        var next = root.calQueue.shift()
        Qt.callLater(function () { root.runCal(next) })
      }
    }
  }

  // Sync every minute while the window is open (and once when it opens).
  Timer {
    interval: 60000
    running: root.live
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      // Picks up a credentials file written at the Agent Cloud path after the window opened.
      if (!root.calendarsPrimary) hostedFile.reload()
      if (!root.busy && root.calQueue.length === 0) root.runCal(["sync"])
    }
  }

  Process {
    id: rmProc
    onExited: root.runRemove()
  }

  Process {
    id: bodyDirProc
    command: ["mkdir", "-p", "-m", "700", root.cloudBodyDir]
    Component.onCompleted: running = true
  }

  Timer {
    interval: 30000
    running: root.live
    repeat: true
    onTriggered: {
      var now = new Date()
      if (Model.keyForDate(now) === String(root.todayKey)) return
      var followToday = root.viewingCurrentMonth && root.selectedKey === root.todayKey
      root.today = now
      if (followToday) root.goToToday()
    }
  }

  Item {
    id: sidebar
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    width: root.sidebarCollapsed ? root.sidebarRailWidth : root.sidebarWidth
    clip: true

    Behavior on width {
      NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
    }

    Item {
      id: sideHeadingRow
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      height: headerActions.height

      Text {
        id: collapseGlyph
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: root.sidebarCollapsed ? parent.width : Style.space(18)
        height: Style.space(18)
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        text: root.sidebarCollapsed ? "›" : "‹"
        color: collapseMouse.containsMouse
          ? root.contentForeground
          : Qt.darker(root.contentForeground, 1.45)
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.body
        font.bold: true

        MouseArea {
          id: collapseMouse
          anchors.fill: parent
          anchors.margins: -Style.space(6)
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.setSidebarCollapsed(!root.sidebarCollapsed)
        }
      }

      Text {
        id: addGlyph
        visible: !root.sidebarCollapsed
        anchors.right: syncGlyph.left
        anchors.rightMargin: Style.space(2)
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(18)
        height: Style.space(18)
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        text: root.addingCalendar ? "−" : "+"
        color: addGlyphMouse.containsMouse || root.addingCalendar
          ? root.contentForeground
          : Qt.darker(root.contentForeground, 1.45)
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.body
        font.bold: true

        MouseArea {
          id: addGlyphMouse
          anchors.fill: parent
          anchors.margins: -Style.space(6)
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.addingCalendar ? root.closeAddForm() : root.openAddForm()
        }
      }

      Text {
        id: syncGlyph
        visible: !root.sidebarCollapsed
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(18)
        height: Style.space(18)
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        text: "󰑐"
        color: syncMouse.containsMouse
          ? Style.hoverStateColor(root.contentForeground, Color.accent)
          : Qt.darker(root.contentForeground, 1.45)
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.icon

        RotationAnimation on rotation {
          running: root.busy
          loops: Animation.Infinite
          from: 0
          to: 360
          duration: 800
          onRunningChanged: if (!running) syncGlyph.rotation = 0
        }

        MouseArea {
          id: syncMouse
          anchors.fill: parent
          anchors.margins: -Style.space(6)
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.runCal(["sync"])
        }
      }
    }

    Column {
      id: calendarList
      anchors.top: sideHeadingRow.bottom
      anchors.topMargin: Style.space(14)
      anchors.left: parent.left
      anchors.right: parent.right
      spacing: Style.space(4)

      Repeater {
        model: root.calendars

        Item {
          id: calRow
          required property var modelData
          width: calendarList.width
          height: Style.space(28)

          HoverHandler {
            id: rowHover
          }

          Rectangle {
            anchors.fill: parent
            radius: 0
            color: calMouse.containsMouse
              ? Style.hoverFillFor(root.contentForeground, Color.accent)
              : "transparent"
          }

          Rectangle {
            id: calDot
            anchors.left: parent.left
            anchors.leftMargin: root.sidebarCollapsed ? Math.max(0, (parent.width - width) / 2) : Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(8)
            height: Style.space(8)
            radius: width / 2
            color: modelData.color || Style.selectedStateColor(root.contentForeground, Color.accent)
            opacity: modelData.enabled === false ? 0.35 : 1
          }

          Text {
            visible: !root.sidebarCollapsed
            anchors.left: calDot.right
            anchors.leftMargin: Style.space(10)
            anchors.right: infoGlyph.left
            anchors.rightMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            text: modelData.name || modelData.id
            elide: Text.ElideRight
            color: root.contentForeground
            opacity: modelData.enabled === false ? 0.4 : 1
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
          }

          Text {
            id: infoGlyph
            visible: !root.sidebarCollapsed && rowHover.hovered
            anchors.right: parent.right
            anchors.rightMargin: Style.space(2)
            anchors.verticalCenter: parent.verticalCenter
            width: visible ? Style.space(18) : 0
            height: Style.space(18)
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            text: "󰋽"
            color: infoMouse.containsMouse
              ? root.contentForeground
              : Qt.darker(root.contentForeground, 1.55)
            opacity: modelData.enabled === false ? 0.45 : 1
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.icon

            MouseArea {
              id: infoMouse
              anchors.fill: parent
              anchors.margins: -Style.space(4)
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.detailCalendar = modelData
            }
          }

          MouseArea {
            id: calMouse
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.right: root.sidebarCollapsed ? parent.right : infoGlyph.left
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.runCal(["toggle", modelData.id])
          }
        }
      }

      Text {
        visible: root.calendars.length === 0 && !root.sidebarCollapsed
        text: "Local only"
        color: Qt.darker(root.contentForeground, 1.85)
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
      }
    }

    Column {
      anchors.top: calendarList.bottom
      anchors.topMargin: Style.space(8)
      anchors.left: parent.left
      anchors.right: parent.right
      spacing: Style.space(8)

      Item {
        visible: root.sidebarCollapsed
        width: parent.width
        height: visible ? Style.space(28) : 0

        Text {
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          horizontalAlignment: Text.AlignHCenter
          text: "+"
          color: addMouse.containsMouse
            ? root.contentForeground
            : Qt.darker(root.contentForeground, 1.45)
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.body
        }

        MouseArea {
          id: addMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            if (root.sidebarCollapsed) root.openAddForm()
            else if (root.addingCalendar) root.closeAddForm()
            else root.openAddForm()
          }
        }
      }

      Column {
        width: parent.width
        spacing: Style.space(8)
        visible: root.addingCalendar
        height: visible ? implicitHeight : 0

        Rectangle {
          width: parent.width
          height: Style.space(32)
          color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.08)

          TextInput {
            id: nameField
            anchors.fill: parent
            anchors.leftMargin: Style.space(10)
            anchors.rightMargin: Style.space(10)
            verticalAlignment: TextInput.AlignVCenter
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            clip: true
            selectByMouse: true
            Keys.onPressed: function (event) {
              if (event.key === Qt.Key_Escape) {
                root.closeAddForm()
                event.accepted = true
              }
            }
          }

          Text {
            anchors.fill: nameField
            verticalAlignment: Text.AlignVCenter
            text: "Name"
            visible: nameField.text === "" && !nameField.activeFocus
            color: Qt.darker(root.contentForeground, 2.0)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Rectangle {
          width: parent.width
          height: Style.space(32)
          color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.08)

          TextInput {
            id: urlField
            anchors.fill: parent
            anchors.leftMargin: Style.space(10)
            anchors.rightMargin: Style.space(10)
            verticalAlignment: TextInput.AlignVCenter
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            clip: true
            selectByMouse: true
            onAccepted: root.subscribeFromFields()
            Keys.onPressed: function (event) {
              if (event.key === Qt.Key_Escape) {
                root.closeAddForm()
                event.accepted = true
              }
            }
          }

          Text {
            anchors.fill: urlField
            verticalAlignment: Text.AlignVCenter
            text: "ICS URL"
            visible: urlField.text === "" && !urlField.activeFocus
            color: Qt.darker(root.contentForeground, 2.0)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          text: root.busy ? "Adding…" : "Subscribe"
          color: subscribeMouse.containsMouse
            ? Style.hoverStateColor(root.contentForeground, Color.accent)
            : root.contentForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          leftPadding: Style.space(6)
          topPadding: Style.space(4)
          bottomPadding: Style.space(4)

          MouseArea {
            id: subscribeMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.subscribeFromFields()
          }
        }
      }

      Text {
        width: sidebar.width
        visible: root.statusText !== "" && !root.sidebarCollapsed
        text: root.statusText
        wrapMode: Text.Wrap
        color: Qt.darker(root.contentForeground, 1.45)
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  Item {
    id: main
    anchors.left: sidebar.right
    anchors.leftMargin: Style.space(16)
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.bottom: parent.bottom

    Item {
      id: header
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      height: monthRow.height + Style.space(22) + yearBlock.height

      Item {
        id: monthRow
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: headerActions.height + Style.space(14) + monthTitle.height

        Item {
          id: headerActions
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          height: Style.space(36)

          Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: 0

            Repeater {
              model: root.viewModes

              Text {
                required property var modelData
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.label
                color: root.viewMode === modelData.id
                  ? root.contentForeground
                  : (modeMouse.containsMouse
                    ? Style.hoverStateColor(root.contentForeground, Color.accent)
                    : Qt.darker(root.contentForeground, 1.45))
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.body
                font.bold: root.viewMode === modelData.id
                leftPadding: Style.space(10)
                rightPadding: Style.space(10)
                topPadding: Style.space(6)
                bottomPadding: Style.space(6)

                Rectangle {
                  anchors.fill: parent
                  z: -1
                  color: root.viewMode === modelData.id
                    ? Style.hoverFillFor(root.contentForeground, Color.accent)
                    : "transparent"
                }

                MouseArea {
                  id: modeMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.viewMode = modelData.id
                }
              }
            }
          }

          Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "New"
              color: newMouse.containsMouse
                ? Style.hoverStateColor(root.contentForeground, Color.accent)
                : root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              leftPadding: Style.space(8)
              rightPadding: Style.space(8)
              topPadding: Style.space(4)
              bottomPadding: Style.space(4)
              MouseArea {
                id: newMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openNewEvent()
              }
            }

            PanelActionButton {
              iconText: "󰅁"
              tooltipText: "Previous " + root.stepLabel
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              onClicked: root.moveStep(-1)
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "Today"
              color: todayMouse.containsMouse
                ? Style.hoverStateColor(root.contentForeground, Color.accent)
                : (root.viewingToday ? root.contentForeground : Qt.darker(root.contentForeground, 1.35))
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              leftPadding: Style.space(8)
              rightPadding: Style.space(8)
              topPadding: Style.space(4)
              bottomPadding: Style.space(4)

              MouseArea {
                id: todayMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.goToToday()
              }
            }

            PanelActionButton {
              iconText: "󰅂"
              tooltipText: "Next " + root.stepLabel
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              onClicked: root.moveStep(1)
            }
          }
        }

        Text {
          id: monthTitle
          anchors.top: headerActions.bottom
          anchors.topMargin: Style.space(14)
          anchors.left: parent.left
          anchors.right: parent.right
          text: root.headerTitle
          wrapMode: Text.WordWrap
          maximumLineCount: 2
          color: root.contentForeground
          font.family: root.contentFontFamily
          font.pixelSize: 42
          font.bold: true
        }
      }

      Item {
        id: yearBlock
        anchors.top: monthRow.bottom
        anchors.topMargin: Style.space(22)
        anchors.left: parent.left
        anchors.right: parent.right
        height: Math.max(yearLabel.implicitHeight, Style.space(10))

        Text {
          id: yearLabel
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: root.today.getFullYear()
          color: Qt.darker(root.contentForeground, 1.55)
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          font.letterSpacing: 1.4
        }

        Text {
          id: yearPercent
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: root.yearDonePercent + "%"
          color: Qt.darker(root.contentForeground, 1.35)
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          font.letterSpacing: 0.8
        }

        Rectangle {
          anchors.left: yearLabel.right
          anchors.right: yearPercent.left
          anchors.leftMargin: Style.space(14)
          anchors.rightMargin: Style.space(14)
          anchors.verticalCenter: parent.verticalCenter
          height: Style.space(4)
          radius: 0
          color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.10)

          Rectangle {
            width: Math.round(parent.width * root.yearDone)
            height: parent.height
            radius: parent.radius
            color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.34)
          }
        }
      }
    }

    Item {
      id: dayPane
      visible: root.viewMode === "month"
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: {
        if (!visible) return 0
        var rows = Math.max(1, root.selectedEvents.length)
        var content = Style.space(20) + dayHeading.implicitHeight + Style.space(14)
          + rows * Style.space(44) + Math.max(0, rows - 1) * Style.space(6) + Style.space(8)
        return Math.min(Math.round(root.height * 0.28), content)
      }

      Rectangle {
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: Style.spacing.hairline
        color: root.contentForeground
        opacity: 0.10
      }

      Text {
        id: dayHeading
        anchors.top: parent.top
        anchors.topMargin: Style.space(20)
        anchors.left: parent.left
        text: root.selectedLabel.toUpperCase()
        color: Qt.darker(root.contentForeground, 1.5)
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
        font.letterSpacing: 1.6
      }

      ListView {
        anchors.top: dayHeading.bottom
        anchors.topMargin: Style.space(14)
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        clip: true
        model: root.viewMode === "month" ? root.selectedEvents : []
        spacing: Style.space(6)

        delegate: Item {
          width: ListView.view.width
          height: Style.space(44)

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.openEvent(modelData)
          }

          Rectangle {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: Style.space(3)
            radius: 0
            color: root.eventColor(modelData)
          }

          Text {
            anchors.left: parent.left
            anchors.leftMargin: Style.space(16)
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(64)
            text: modelData.allDay || !modelData.start ? "All day" : modelData.start
            color: Qt.darker(root.contentForeground, 1.45)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
          }

          Text {
            anchors.left: parent.left
            anchors.leftMargin: Style.space(88)
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: modelData.title
            elide: Text.ElideRight
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
          }
        }

        Text {
          visible: root.selectedEvents.length === 0
          anchors.top: parent.top
          anchors.left: parent.left
          text: "Nothing scheduled"
          color: Qt.darker(root.contentForeground, 1.85)
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.body
        }
      }
    }

    Item {
      id: bodyHost
      anchors.top: header.bottom
      anchors.topMargin: Style.space(16)
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: dayPane.visible ? dayPane.top : parent.bottom
      anchors.bottomMargin: Style.space(8)

      WheelHandler {
        enabled: root.viewMode === "month" || root.viewMode === "year"
        onWheel: function (event) {
          if (event.angleDelta.y === 0) return
          root.moveStep(event.angleDelta.y > 0 ? -1 : 1)
        }
      }

      Loader {
        id: modeLoader
        anchors.fill: parent
        active: root.live
        sourceComponent: {
          if (root.viewMode === "day") return dayComp
          if (root.viewMode === "week") return weekComp
          if (root.viewMode === "year") return yearComp
          return monthComp
        }
      }
    }
  }

  Component { id: dayComp; DayView { host: root } }
  Component { id: weekComp; WeekView { host: root } }
  Component { id: monthComp; MonthView { host: root } }
  Component { id: yearComp; YearView { host: root } }

  CalendarDetail {
    anchors.fill: parent
    host: root
    calendar: root.detailCalendar
  }

  EventEditor {
    anchors.fill: parent
    host: root
    event: root.editingEvent
  }
}
