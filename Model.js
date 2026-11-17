// Pure date and format math for the clock widget and its calendar panel.
// Everything here is locale- and Qt-free so it can be unit tested under node
// (test/shell.d/clock-test.sh); the QML owns month/weekday naming through
// Qt.locale().

var MS_PER_DAY = 86400000

// Weekday indices match both JS Date.getDay() and QML's Locale.Sunday…
// Locale.Saturday, so a locale's firstDayOfWeek can be passed straight in.
var WEEKDAY_NAMES = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

// ---- Bar label formats. Right-clicking the clock walks these in order and
//      writes the result back to shell.json, so the label the bar shows and
//      the format the config stores are always the same thing.
//
// The locale-shaped time presets are each followed by their 12-hour twin, so
// the walk from a 24-hour label to the same label in AM/PM is a single right
// click rather than a lap of the ring. The ISO preset is deliberately left
// without one: ISO 8601 writes time on a 24-hour clock, so an AM/PM variant
// would contradict the only thing that format is for.
var CLOCK_FORMATS = [
  "dddd HH:mm",
  "dddd h:mm AP",
  "HH:mm",
  "h:mm AP",
  "ddd d MMM HH:mm",
  "ddd d MMM h:mm AP",
  "d MMMM 'W'ww yyyy",
  "yyyy-MM-dd HH:mm"
]

// Vertical bars have room for a few stacked lines and nothing else, so the
// ring stays short. AM/PM costs a fourth line, which is why only the plain
// time carries it here.
var VERTICAL_CLOCK_FORMATS = [
  "HH\n—\nmm",
  "h\n—\nmm\nAP",
  "dd\nMMM\n'W'ww\n''yy",
  "HH\nmm"
]

function clockFormats(vertical) {
  return vertical ? VERTICAL_CLOCK_FORMATS.slice() : CLOCK_FORMATS.slice()
}

// The presets in a fixed order, plus the configured alternate and current
// format when they are something else. The order must not depend on which
// entry is current: cycling writes the result back to shell.json, and a ring
// that reshuffled itself around the current value would bounce between two
// entries instead of walking.
function clockFormatRing(configured, configuredAlt, presets) {
  const ring = []
  const candidates = (presets || []).concat([configuredAlt, configured])
  for (let i = 0; i < candidates.length; i++) {
    const format = String(candidates[i] === undefined || candidates[i] === null ? "" : candidates[i])
    if (format === "" || ring.indexOf(format) !== -1) continue
    ring.push(format)
  }
  return ring.length > 0 ? ring : ["HH:mm"]
}

// Next entry after `current`. An unknown current format (a hand-written one
// that is not in the ring) starts the walk at the top.
function nextClockFormat(ring, current) {
  if (!ring || ring.length === 0) return ""
  const index = ring.indexOf(String(current === undefined || current === null ? "" : current))
  return ring[(index + 1) % ring.length]
}

// Two-digit ISO week, substituted into a format's 'ww' token before Qt
// formats it -- Qt has no ISO week specifier of its own.
function isoWeekLiteral(year, month, day) {
  return pad2(isoWeek(year, month, day))
}

function pad2(value) {
  const n = Number(value)
  return (n < 10 ? "0" : "") + n
}

// Stable "yyyy-MM-dd" identity for a day, so a grid cell can be compared
// against today without dragging Date objects through bindings.
function dateKey(year, month, day) {
  return year + "-" + pad2(Number(month) + 1) + "-" + pad2(day)
}

function keyForDate(date) {
  return dateKey(date.getFullYear(), date.getMonth(), date.getDate())
}

function parseDateKey(key) {
  const parts = String(key || "").split("-")
  if (parts.length !== 3) return null
  const year = parseInt(parts[0], 10)
  const month = parseInt(parts[1], 10) - 1
  const day = parseInt(parts[2], 10)
  if (!isFinite(year) || !isFinite(month) || !isFinite(day)) return null
  return { year: year, month: month, day: day }
}

function eventSortKey(event) {
  if (!event) return "9"
  if (event.allDay || !event.start) return "0|" + String(event.title || "")
  return "1|" + String(event.start) + "|" + String(event.title || "")
}

function sortDayEvents(list) {
  const copy = (list || []).slice()
  copy.sort(function (a, b) {
    const left = eventSortKey(a)
    const right = eventSortKey(b)
    if (left < right) return -1
    if (left > right) return 1
    return 0
  })
  return copy
}

function parseEventsFile(text) {
  const empty = { events: [], eventsByDate: {}, calendars: [] }
  try {
    const data = JSON.parse(String(text || "") || "{}")
    const calendars = data.calendars || []
    let enabled = null
    if (calendars.length > 0) {
      enabled = {}
      for (let c = 0; c < calendars.length; c++) {
        const cal = calendars[c]
        if (!cal || !cal.id) continue
        enabled[cal.id] = cal.enabled !== false
      }
    }
    const events = data.events || []
    const counts = {}
    const visible = []
    const byDate = {}
    for (let i = 0; i < events.length; i++) {
      const event = events[i]
      const key = event && event.dateKey
      if (!key) continue
      const calId = event.calendarId || ""
      if (calId) counts[calId] = (counts[calId] || 0) + 1
      if (enabled && calId && enabled[calId] === false) continue
      visible.push(event)
      if (!byDate[key]) byDate[key] = []
      byDate[key].push(event)
    }
    for (let n = 0; n < calendars.length; n++) {
      if (!calendars[n] || !calendars[n].id) continue
      calendars[n].eventCount = counts[calendars[n].id] || 0
    }
    const dates = Object.keys(byDate)
    for (let d = 0; d < dates.length; d++) byDate[dates[d]] = sortDayEvents(byDate[dates[d]])
    return { events: visible, eventsByDate: byDate, calendars: calendars }
  } catch (err) {
    return empty
  }
}

function eventsForDay(byDate, key) {
  if (!byDate || !key) return []
  return byDate[key] || []
}

function dayHasEvents(byDate, key) {
  const list = eventsForDay(byDate, key)
  return list.length > 0
}

function formatSelectedDateLabel(key, todayKey) {
  const parsed = parseDateKey(key)
  if (!parsed) return ""
  if (key === todayKey) return "Today"
  const date = new Date(parsed.year, parsed.month, parsed.day)
  const days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
  const months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
  return days[date.getDay()] + " " + parsed.day + " " + months[parsed.month]
}

function coerceWeekStart(value) {
  if (value === undefined || value === null) return null
  if (typeof value === "number")
    return isFinite(value) ? ((Math.round(value) % 7) + 7) % 7 : null

  const text = String(value).replace(/^\s+|\s+$/g, "").toLowerCase()
  if (text === "") return null

  for (let i = 0; i < WEEKDAY_NAMES.length; i++)
    if (WEEKDAY_NAMES[i] === text || WEEKDAY_NAMES[i].substr(0, 3) === text) return i

  const parsed = parseInt(text, 10)
  return isFinite(parsed) ? ((parsed % 7) + 7) % 7 : null
}

// Configured week start, falling back to the locale's own first day when
// the setting is missing or nonsense.
function normalizedWeekStart(value, fallback) {
  const configured = coerceWeekStart(value)
  if (configured !== null) return configured
  const fallbackStart = coerceWeekStart(fallback)
  return fallbackStart === null ? 1 : fallbackStart
}

function weekStartSettingName(index) {
  return WEEKDAY_NAMES[normalizedWeekStart(index, 1)]
}

// The toggle flips between the two conventions people actually switch
// between. A calendar configured to any other start (Saturday, say) is
// shown as-is and lands on Monday the first time it is toggled.
function toggledWeekStart(index) {
  return normalizedWeekStart(index, 1) === 1 ? 0 : 1
}

function weekdayOrder(weekStart) {
  const start = normalizedWeekStart(weekStart, 1)
  const out = []
  for (let i = 0; i < 7; i++) out.push((start + i) % 7)
  return out
}

// ISO-8601 week number: the week owning the Thursday of that date's
// Monday-based week. Mirrors the clock widget's 'ww' format token.
function isoWeek(year, month, day) {
  const date = new Date(Date.UTC(year, month, day))
  const weekday = date.getUTCDay() || 7
  date.setUTCDate(date.getUTCDate() + 4 - weekday)
  const yearStart = new Date(Date.UTC(date.getUTCFullYear(), 0, 1))
  return Math.ceil(((date.getTime() - yearStart.getTime()) / MS_PER_DAY + 1) / 7)
}

function dayOfYear(year, month, day) {
  return Math.round((Date.UTC(year, month, day) - Date.UTC(year, 0, 1)) / MS_PER_DAY) + 1
}

function daysInYear(year) {
  return dayOfYear(year, 11, 31)
}

// Share of the year already behind you: whole days completed over days in
// the year, so January 1 reads 0% and December 31 reads 100%.
function yearProgress(year, month, day) {
  const total = daysInYear(year)
  if (total <= 0) return 0
  return Math.max(0, Math.min(1, (dayOfYear(year, month, day) - 1) / total))
}

function yearProgressPercent(year, month, day) {
  return Math.round(yearProgress(year, month, day) * 100)
}

// Memento mori. The default span is a round number rather than anything from
// an actuarial table: the point of the bar is the reminder, not the
// arithmetic, and whoever wants a different number can say so.
var DEFAULT_LIFE_EXPECTANCY = 90

// A birth year rather than an age, so the bar keeps counting on its own
// instead of going stale the moment it is entered. 0 means "not set", which
// is also what a blank, malformed, future, or implausibly distant year means.
function parseBirthYear(value, currentYear) {
  const now = Math.round(Number(currentYear))
  if (!isFinite(now)) return 0
  const text = String(value === undefined || value === null ? "" : value).replace(/^\s+|\s+$/g, "")
  if (!/^\d{4}$/.test(text)) return 0
  const year = parseInt(text, 10)
  if (!isFinite(year) || year > now || year < now - 120) return 0
  return year
}

// Whole years, the way people say their age: born in 1979 makes you 47 for
// all of 2026, whichever side of your birthday today falls.
function ageFromBirthYear(birthYear, currentYear) {
  const born = parseBirthYear(birthYear, currentYear)
  if (born <= 0) return 0
  return Math.round(Number(currentYear)) - born
}

// 0 means "not set", which is also what a blank, negative, fractional, or
// absurd entry means — the life bar simply stays hidden.
function parseAge(value) {
  const text = String(value === undefined || value === null ? "" : value).replace(/^\s+|\s+$/g, "")
  if (!/^\d+$/.test(text)) return 0
  const years = parseInt(text, 10)
  if (!isFinite(years) || years <= 0 || years > 120) return 0
  return years
}

// Unset or nonsense falls back to the default rather than to zero, so the
// bar always has something to measure against.
function parseLifeExpectancy(value) {
  const text = String(value === undefined || value === null ? "" : value).replace(/^\s+|\s+$/g, "")
  if (!/^\d+$/.test(text)) return DEFAULT_LIFE_EXPECTANCY
  const years = parseInt(text, 10)
  if (!isFinite(years) || years <= 0 || years > 150) return DEFAULT_LIFE_EXPECTANCY
  return years
}

function lifeProgress(age, expectancy) {
  const years = parseAge(age)
  const span = parseLifeExpectancy(expectancy)
  if (years <= 0 || span <= 0) return 0
  return Math.max(0, Math.min(1, years / span))
}

function lifeProgressPercent(age, expectancy) {
  return Math.round(lifeProgress(age, expectancy) * 100)
}

// Always six rows of seven days. A fixed grid keeps the popup exactly the
// same height in every month, so stepping through the year never makes the
// panel jump under the pointer.
function monthGrid(year, month, weekStart, todayKey) {
  const start = normalizedWeekStart(weekStart, 1)
  const leading = (new Date(year, month, 1).getDay() - start + 7) % 7
  const cursor = new Date(year, month, 1 - leading)
  const today = String(todayKey || "")
  const weeks = []

  for (let w = 0; w < 6; w++) {
    const days = []
    let thursday = null
    for (let d = 0; d < 7; d++) {
      const cellYear = cursor.getFullYear()
      const cellMonth = cursor.getMonth()
      const cellDay = cursor.getDate()
      const weekday = cursor.getDay()
      const key = dateKey(cellYear, cellMonth, cellDay)
      if (weekday === 4) thursday = { year: cellYear, month: cellMonth, day: cellDay }
      days.push({
        key: key,
        year: cellYear,
        month: cellMonth,
        day: cellDay,
        weekday: weekday,
        inMonth: cellMonth === month && cellYear === year,
        weekend: weekday === 0 || weekday === 6,
        today: key === today
      })
      cursor.setDate(cursor.getDate() + 1)
    }
    // Number every row by the ISO week owning its Thursday. That is the
    // definition itself for Monday-start weeks, and the only answer that
    // stays stable for the other starts, where a row straddles two ISO
    // weeks but shares all of Monday through Thursday with one of them.
    const anchor = thursday || days[0]
    weeks.push({
      week: isoWeek(anchor.year, anchor.month, anchor.day),
      days: days
    })
  }
  return weeks
}

function stepMonth(year, month, delta) {
  const target = new Date(year, Number(month) + Number(delta), 1)
  return { year: target.getFullYear(), month: target.getMonth() }
}

function addDaysFromKey(key, delta) {
  const parsed = parseDateKey(key)
  if (!parsed) return null
  const date = new Date(parsed.year, parsed.month, parsed.day + Number(delta))
  return {
    year: date.getFullYear(),
    month: date.getMonth(),
    day: date.getDate(),
    key: keyForDate(date)
  }
}

function weekDaysFromKey(key, weekStart, todayKey) {
  const parsed = parseDateKey(key)
  if (!parsed) return []
  const start = normalizedWeekStart(weekStart, 1)
  const leading = (new Date(parsed.year, parsed.month, parsed.day).getDay() - start + 7) % 7
  const cursor = new Date(parsed.year, parsed.month, parsed.day - leading)
  const today = String(todayKey || "")
  const days = []
  for (let i = 0; i < 7; i++) {
    const cellYear = cursor.getFullYear()
    const cellMonth = cursor.getMonth()
    const cellDay = cursor.getDate()
    const weekday = cursor.getDay()
    const cellKey = dateKey(cellYear, cellMonth, cellDay)
    days.push({
      key: cellKey,
      year: cellYear,
      month: cellMonth,
      day: cellDay,
      weekday: weekday,
      weekend: weekday === 0 || weekday === 6,
      today: cellKey === today
    })
    cursor.setDate(cursor.getDate() + 1)
  }
  return days
}

function formatWeekTitle(days) {
  if (!days || days.length < 2) return ""
  const months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
  const a = days[0]
  const b = days[days.length - 1]
  if (a.year === b.year && a.month === b.month)
    return months[a.month] + " " + a.day + "–" + b.day + ", " + a.year
  if (a.year === b.year)
    return months[a.month].slice(0, 3) + " " + a.day + " – " + months[b.month].slice(0, 3) + " " + b.day + ", " + a.year
  return months[a.month].slice(0, 3) + " " + a.day + ", " + a.year + " – " + months[b.month].slice(0, 3) + " " + b.day + ", " + b.year
}

var yearMonthsCache = { key: "", months: [] }

function yearMonths(year, weekStart, todayKey) {
  const key = year + "|" + weekStart + "|" + todayKey
  if (yearMonthsCache.key === key) return yearMonthsCache.months
  const out = []
  for (let m = 0; m < 12; m++) {
    out.push({
      year: year,
      month: m,
      weeks: monthGrid(year, m, weekStart, todayKey)
    })
  }
  yearMonthsCache = { key: key, months: out }
  return out
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

function eventPlacement(event) {
  if (!event) return { allDay: true, startMin: 0, endMin: 60 }
  const start = parseMinutes(event.start)
  if (event.allDay || start === null)
    return { allDay: true, startMin: 0, endMin: 60 }
  let end = parseMinutes(event.end)
  if (end === null || end <= start) end = start + 60
  return { allDay: false, startMin: start, endMin: end }
}

function allDayEvents(list) {
  const out = []
  const events = list || []
  for (let i = 0; i < events.length; i++) {
    if (eventPlacement(events[i]).allDay) out.push(events[i])
  }
  return out
}

function timedEvents(list) {
  const out = []
  const events = list || []
  for (let i = 0; i < events.length; i++) {
    if (!eventPlacement(events[i]).allDay) out.push(events[i])
  }
  return out
}

var HOUR_SLOTS = null

function hourSlots() {
  if (HOUR_SLOTS) return HOUR_SLOTS
  const out = []
  for (let h = 0; h < 24; h++) {
    let hour12 = h % 12
    if (hour12 === 0) hour12 = 12
    out.push({
      hour: h,
      label: h === 0 ? "" : (hour12 + (h < 12 ? " AM" : " PM"))
    })
  }
  HOUR_SLOTS = out
  return out
}

if (typeof module !== "undefined") {
  module.exports = {
    dateKey: dateKey,
    keyForDate: keyForDate,
    parseDateKey: parseDateKey,
    formatSelectedDateLabel: formatSelectedDateLabel,
    parseEventsFile: parseEventsFile,
    sortDayEvents: sortDayEvents,
    eventsForDay: eventsForDay,
    dayHasEvents: dayHasEvents,
    normalizedWeekStart: normalizedWeekStart,
    weekStartSettingName: weekStartSettingName,
    toggledWeekStart: toggledWeekStart,
    weekdayOrder: weekdayOrder,
    isoWeek: isoWeek,
    dayOfYear: dayOfYear,
    daysInYear: daysInYear,
    yearProgress: yearProgress,
    yearProgressPercent: yearProgressPercent,
    parseAge: parseAge,
    parseBirthYear: parseBirthYear,
    ageFromBirthYear: ageFromBirthYear,
    parseLifeExpectancy: parseLifeExpectancy,
    lifeProgress: lifeProgress,
    lifeProgressPercent: lifeProgressPercent,
    monthGrid: monthGrid,
    stepMonth: stepMonth,
    addDaysFromKey: addDaysFromKey,
    weekDaysFromKey: weekDaysFromKey,
    formatWeekTitle: formatWeekTitle,
    yearMonths: yearMonths,
    parseMinutes: parseMinutes,
    eventPlacement: eventPlacement,
    allDayEvents: allDayEvents,
    timedEvents: timedEvents,
    hourSlots: hourSlots,
    clockFormats: clockFormats,
    clockFormatRing: clockFormatRing,
    nextClockFormat: nextClockFormat,
    isoWeekLiteral: isoWeekLiteral
  }
}
