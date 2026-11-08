// Almanac hosted events. No I/O. QML and Node tests share this file.

function trim(s) {
  return String(s || "").replace(/^\s+|\s+$/g, "")
}

function pad2(value) {
  var n = Number(value)
  return (n < 10 ? "0" : "") + n
}

function parseCalendars(raw) {
  var parsed = null
  try { parsed = JSON.parse(String(raw || "")) } catch (e) { return [] }
  var list = []
  if (Array.isArray(parsed)) list = parsed
  else if (parsed && Array.isArray(parsed.calendars)) list = parsed.calendars
  else if (parsed && parsed.id) list = [parsed]
  var out = []
  for (var i = 0; i < list.length; i++) {
    var row = list[i]
    if (!row || !row.id) continue
    out.push({
      id: String(row.id),
      name: trim(row.name) || "Almanac",
      subscribe: trim(row.subscribe)
    })
  }
  return out
}

function resolveCalendar(calendars, wantedId) {
  var list = calendars || []
  if (!list.length) return null
  var want = trim(wantedId)
  if (want) {
    for (var i = 0; i < list.length; i++) if (list[i].id === want) return list[i]
    return null
  }
  return list[0]
}

function eventUid(event) {
  if (!event) return ""
  if (event.uid) return String(event.uid)
  var id = String(event.id || "")
  var cal = String(event.calendarId || "")
  var key = String(event.dateKey || "")
  var prefix = cal + ":"
  var suffix = ":" + key
  if (cal && key && id.indexOf(prefix) === 0 && id.slice(-suffix.length) === suffix)
    return id.slice(prefix.length, id.length - suffix.length)
  return ""
}

function isAlmanacUrl(url) {
  return String(url || "").indexOf("almanac.dottie.ai") >= 0
}

function isWritable(event, calendars) {
  if (!event) return false
  if (String(event.calendarId || "") === "almanac") return true
  var id = String(event.calendarId || "")
  var rows = calendars || []
  for (var i = 0; i < rows.length; i++) {
    if (rows[i] && rows[i].id === id && isAlmanacUrl(rows[i].url)) return true
  }
  return false
}

function parseMinutes(value) {
  var text = String(value || "")
  var parts = text.split(":")
  if (parts.length < 2) return null
  var hour = parseInt(parts[0], 10)
  var minute = parseInt(parts[1], 10)
  if (!isFinite(hour) || hour < 0 || hour > 23) return null
  if (!isFinite(minute) || minute < 0 || minute > 59) minute = 0
  return hour * 60 + minute
}

function offsetFor(dateKey, hm) {
  var parts = String(dateKey || "").split("-")
  if (parts.length !== 3) return "-07:00"
  var year = parseInt(parts[0], 10)
  var month = parseInt(parts[1], 10) - 1
  var day = parseInt(parts[2], 10)
  var mins = parseMinutes(hm)
  if (mins === null) mins = 9 * 60
  var date = new Date(year, month, day, Math.floor(mins / 60), mins % 60, 0)
  var off = -date.getTimezoneOffset()
  var sign = off >= 0 ? "+" : "-"
  var abs = Math.abs(off)
  return sign + pad2(Math.floor(abs / 60)) + ":" + pad2(abs % 60)
}

function isoWhen(dateKey, hm) {
  var mins = parseMinutes(hm)
  if (mins === null) mins = 9 * 60
  return dateKey + "T" + pad2(Math.floor(mins / 60)) + ":" + pad2(mins % 60) + ":00" + offsetFor(dateKey, hm)
}

function buildEventBody(draft) {
  var summary = trim(draft && draft.title)
  if (!summary) return { error: "Need a title" }
  if (summary.length > 512) return { error: "512 character title cap" }
  var dateKey = trim(draft && draft.dateKey)
  if (!/^\d{4}-\d{2}-\d{2}$/.test(dateKey)) return { error: "Need a date" }
  var body = { summary: summary }
  var uid = trim(draft && draft.uid)
  if (uid) body.uid = uid
  if (draft && draft.allDay) {
    body.start = dateKey
    body.allDay = true
    return { body: body }
  }
  var start = trim(draft && draft.start) || "09:00"
  var end = trim(draft && draft.end) || ""
  if (parseMinutes(start) === null) return { error: "Need a start time" }
  body.start = isoWhen(dateKey, start)
  if (end && parseMinutes(end) !== null) {
    var startMin = parseMinutes(start)
    var endMin = parseMinutes(end)
    if (endMin <= startMin) endMin = startMin + 60
    body.end = isoWhen(dateKey, pad2(Math.floor(endMin / 60)) + ":" + pad2(endMin % 60))
  }
  return { body: body }
}

// The script prints ERROR:conflict when a --rev is stale (HTTP 412).
function isConflict(raw) {
  return trim(String(raw || "")) === "ERROR:conflict"
}

function errorMessage(raw) {
  var text = String(raw || "")
  if (isConflict(text)) return "Changed elsewhere"
  if (text.indexOf("ERROR:") === 0) text = trim(text.slice(6))
  try {
    var parsed = JSON.parse(text)
    if (parsed && parsed.error) text = String(parsed.error)
  } catch (e) {}
  text = trim(text)
  if (!text) return "Almanac request failed"
  if (text === "unauthorized") return "Almanac key rejected"
  if (text === "rate limit exceeded") return "Almanac write budget"
  if (text === "calendar is full") return "Almanac event cap"
  return text
}

if (typeof module !== "undefined") {
  module.exports = {
    parseCalendars: parseCalendars,
    resolveCalendar: resolveCalendar,
    eventUid: eventUid,
    isWritable: isWritable,
    buildEventBody: buildEventBody,
    isoWhen: isoWhen,
    isConflict: isConflict,
    errorMessage: errorMessage
  }
}
