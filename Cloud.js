// Agent Cloud hosted events (the agentcloud server). No I/O. QML and Node tests share this file.

var PRODUCT = "Agent Cloud"

function trim(s) {
  return String(s || "").replace(/^\s+|\s+$/g, "")
}

function pad2(value) {
  const n = Number(value)
  return (n < 10 ? "0" : "") + n
}

// The old default names ("Almanac", "Dottie") show as Agent Cloud.
function displayName(name) {
  const text = trim(name)
  if (!text || text === "Almanac" || text === "Dottie") return PRODUCT
  return text
}

function parseCalendars(raw) {
  let parsed = null
  try { parsed = JSON.parse(String(raw || "")) } catch (e) { return [] }
  let list = []
  if (Array.isArray(parsed)) list = parsed
  else if (parsed && Array.isArray(parsed.calendars)) list = parsed.calendars
  else if (parsed && parsed.id) list = [parsed]
  const out = []
  for (let i = 0; i < list.length; i++) {
    const row = list[i]
    if (!row || !row.id) continue
    out.push({
      id: String(row.id),
      name: displayName(row.name),
      subscribe: trim(row.subscribe)
    })
  }
  return out
}

function resolveCalendar(calendars, wantedId) {
  const list = calendars || []
  if (!list.length) return null
  const want = trim(wantedId)
  if (want) {
    for (let i = 0; i < list.length; i++) if (list[i].id === want) return list[i]
    return null
  }
  return list[0]
}

function eventUid(event) {
  if (!event) return ""
  if (event.uid) return String(event.uid)
  const id = String(event.id || "")
  const cal = String(event.calendarId || "")
  const key = String(event.dateKey || "")
  const prefix = cal + ":"
  const suffix = ":" + key
  if (cal && key && id.indexOf(prefix) === 0 && id.slice(-suffix.length) === suffix)
    return id.slice(prefix.length, id.length - suffix.length)
  return ""
}

// Agent Cloud feeds, on the current host or the old one.
function isCloudUrl(url) {
  const text = String(url || "")
  return text.indexOf("cloud.bixbyapps.com") >= 0 || text.indexOf("almanac.dottie.ai") >= 0
}

function isWritable(event, calendars) {
  if (!event) return false
  if (String(event.calendarId || "") === "cloud") return true
  const id = String(event.calendarId || "")
  const rows = calendars || []
  for (let i = 0; i < rows.length; i++) {
    if (rows[i] && rows[i].id === id && isCloudUrl(rows[i].url)) return true
  }
  return false
}

function parseMinutes(value) {
  const text = String(value || "")
  const parts = text.split(":")
  if (parts.length < 2) return null
  const hour = parseInt(parts[0], 10)
  let minute = parseInt(parts[1], 10)
  if (!isFinite(hour) || hour < 0 || hour > 23) return null
  if (!isFinite(minute) || minute < 0 || minute > 59) minute = 0
  return hour * 60 + minute
}

function offsetFor(dateKey, hm) {
  const parts = String(dateKey || "").split("-")
  if (parts.length !== 3) return "-07:00"
  const year = parseInt(parts[0], 10)
  const month = parseInt(parts[1], 10) - 1
  const day = parseInt(parts[2], 10)
  let mins = parseMinutes(hm)
  if (mins === null) mins = 9 * 60
  const date = new Date(year, month, day, Math.floor(mins / 60), mins % 60, 0)
  const off = -date.getTimezoneOffset()
  const sign = off >= 0 ? "+" : "-"
  const abs = Math.abs(off)
  return sign + pad2(Math.floor(abs / 60)) + ":" + pad2(abs % 60)
}

function isoWhen(dateKey, hm) {
  let mins = parseMinutes(hm)
  if (mins === null) mins = 9 * 60
  return dateKey + "T" + pad2(Math.floor(mins / 60)) + ":" + pad2(mins % 60) + ":00" + offsetFor(dateKey, hm)
}

function buildEventBody(draft) {
  const summary = trim(draft && draft.title)
  if (!summary) return { error: "Need a title" }
  if (summary.length > 512) return { error: "512 character title cap" }
  const dateKey = trim(draft && draft.dateKey)
  if (!/^\d{4}-\d{2}-\d{2}$/.test(dateKey)) return { error: "Need a date" }
  const body = { summary: summary }
  const uid = trim(draft && draft.uid)
  if (uid) body.uid = uid
  if (draft && draft.allDay) {
    body.start = dateKey
    body.allDay = true
    return { body: body }
  }
  const start = trim(draft && draft.start) || "09:00"
  const end = trim(draft && draft.end) || ""
  if (parseMinutes(start) === null) return { error: "Need a start time" }
  body.start = isoWhen(dateKey, start)
  if (end && parseMinutes(end) !== null) {
    const startMin = parseMinutes(start)
    let endMin = parseMinutes(end)
    if (endMin <= startMin) endMin = startMin + 60
    body.end = isoWhen(dateKey, pad2(Math.floor(endMin / 60)) + ":" + pad2(endMin % 60))
  }
  return { body: body }
}

// The date and times the editor shows for an event (as EventEditor.fill() does).
function editorWhen(event) {
  const allDay = !!(event && (event.allDay || !event.start))
  return {
    dateKey: trim(event && event.dateKey),
    start: allDay ? "09:00" : trim(event.start),
    end: allDay || !event.end ? "10:00" : trim(event.end),
    allDay: allDay
  }
}

// True when a draft keeps the event's date and times: only the title changed.
function sameWhen(event, draft) {
  const was = editorWhen(event)
  const allDay = !!(draft && draft.allDay)
  if (was.allDay !== allDay || was.dateKey !== trim(draft && draft.dateKey)) return false
  return allDay || (trim(draft.start) === was.start && trim(draft.end) === was.end)
}

// True for one date of a repeating event (sd-calendar marks it `repeats`).
function repeats(event) {
  return !!(event && event.repeats)
}

// The date (and start time, "" when all-day) the calendar shows for one
// occurrence: what `cloud-events.sh skip` takes as --date and --time.
function occurrenceOf(event) {
  const allDay = !!(event && (event.allDay || !event.start))
  return { date: trim(event && event.dateKey), time: allDay ? "" : trim(event.start) }
}

// The body that saves an edit the server refused as a new event.
function conflictCopy(body) {
  const suffix = " (conflict copy)"
  const copy = {}
  for (const key in body) if (key !== "uid") copy[key] = body[key]
  copy.summary = trim(body && body.summary).slice(0, 512 - suffix.length) + suffix
  return copy
}

// The script prints ERROR:conflict when a --rev is stale (HTTP 412).
function isConflict(raw) {
  return trim(String(raw || "")) === "ERROR:conflict"
}

function errorMessage(raw) {
  let text = String(raw || "")
  if (isConflict(text)) return "Changed elsewhere"
  if (text.indexOf("ERROR:") === 0) text = trim(text.slice(6))
  try {
    const parsed = JSON.parse(text)
    if (parsed && parsed.error) text = String(parsed.error)
  } catch (e) {}
  text = trim(text)
  if (!text) return PRODUCT + " request failed"
  if (text === "unauthorized") return PRODUCT + " key rejected"
  if (text === "rate limit exceeded") return PRODUCT + " write budget"
  if (text === "calendar is full") return PRODUCT + " event cap"
  return text
}

if (typeof module !== "undefined") {
  module.exports = {
    PRODUCT: PRODUCT,
    displayName: displayName,
    isCloudUrl: isCloudUrl,
    parseCalendars: parseCalendars,
    resolveCalendar: resolveCalendar,
    eventUid: eventUid,
    isWritable: isWritable,
    buildEventBody: buildEventBody,
    isoWhen: isoWhen,
    isConflict: isConflict,
    editorWhen: editorWhen,
    sameWhen: sameWhen,
    conflictCopy: conflictCopy,
    repeats: repeats,
    occurrenceOf: occurrenceOf,
    errorMessage: errorMessage
  }
}
