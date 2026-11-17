import test from "node:test"
import assert from "node:assert/strict"
import Model from "../Model.js"

test("monthGrid is always six rows of seven, numbered by the ISO week of each row's Thursday", () => {
  for (const weekStart of [0, 1]) {
    for (let month = 0; month < 12; month++) {
      const grid = Model.monthGrid(2026, month, weekStart, "")
      assert.equal(grid.length, 6, `month ${month} start ${weekStart}`)
      for (const row of grid) assert.equal(row.days.length, 7)
    }
  }
  const sundayFirst = Model.monthGrid(2026, 0, 0, "")
  assert.equal(sundayFirst[0].days[0].key, "2025-12-28")
  assert.equal(Model.isoWeek(2025, 11, 28), 52)
  assert.deepEqual(sundayFirst.map((row) => row.week), [1, 2, 3, 4, 5, 6])
  const february = Model.monthGrid(2026, 1, 0, "")
  assert.equal(february[0].days[0].key, "2026-02-01")
  assert.equal(february[5].days[6].key, "2026-03-14")
})

test("isoWeekLiteral is the two-digit ISO week Qt cannot format itself", () => {
  assert.equal(Model.isoWeekLiteral(2026, 0, 1), "01")
  assert.equal(Model.isoWeekLiteral(2020, 11, 31), "53")
  assert.equal(Model.isoWeekLiteral(2027, 0, 1), "53")
})

test("cycling clock formats visits every preset once and comes home, whatever entry is current", () => {
  for (const vertical of [false, true]) {
    const presets = Model.clockFormats(vertical)
    for (const start of presets) {
      const seen = []
      let current = start
      for (let i = 0; i < presets.length; i++) {
        current = Model.nextClockFormat(Model.clockFormatRing(current, "", presets), current)
        seen.push(current)
      }
      assert.equal(current, start)
      assert.deepEqual(seen.slice().sort(), presets.slice().sort())
    }
    assert.deepEqual(Model.clockFormatRing(presets[2], "", presets), Model.clockFormatRing(presets[5], "", presets))
  }
})

test("the ISO clock preset is 24-hour only, with no AM/PM twin", () => {
  const iso = Model.clockFormats(false).filter((f) => f.indexOf("yyyy-MM-dd") === 0)
  assert.deepEqual(iso, ["yyyy-MM-dd HH:mm"])
})

test("birth year 0 means not set and covers blank, malformed, future and absurd years", () => {
  for (const value of ["", "  ", null, undefined, "19x0", "199", "2030", "1800", "abcd"]) {
    assert.equal(Model.parseBirthYear(value, 2026), 0, String(value))
    assert.equal(Model.ageFromBirthYear(value, 2026), 0, String(value))
  }
  assert.equal(Model.parseBirthYear(" 1990 ", 2026), 1990)
  assert.equal(Model.ageFromBirthYear("1990", 2026), 36)
  assert.equal(Model.parseLifeExpectancy(""), 90)
  assert.equal(Model.parseLifeExpectancy("0"), 90)
  assert.equal(Model.lifeProgressPercent(45, ""), 50)
})
