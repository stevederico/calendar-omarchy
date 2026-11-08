const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const http = require("node:http")
const os = require("node:os")
const path = require("node:path")
const { spawn } = require("node:child_process")
const Almanac = require("../Almanac.js")
const crypto = require("node:crypto")
const TOKEN = crypto.createHash("sha256").update("test-key" + "almanac-auth-v1").digest("hex")

function writeConfig(dir, port) {
  const config = path.join(dir, "hosted-calendars.json")
  fs.writeFileSync(config, JSON.stringify([{
    id: "cal_test",
    name: "Almanac",
    key: "test-key",
    write: `http://127.0.0.1:${port}/v1/c/cal_test/events`,
    subscribe: `http://127.0.0.1:${port}/feed.ics`
  }]))
  return config
}

function listen(server) {
  return new Promise((resolve) => {
    server.listen(0, "127.0.0.1", () => resolve(server.address().port))
  })
}

function runScript(args, env, input) {
  return new Promise((resolve) => {
    const child = spawn("bash", [path.join(__dirname, "..", "scripts", "almanac-events.sh"), ...args], {
      env: { ...process.env, ...env }
    })
    child.stdin.end(input || "")
    let stdout = ""
    let stderr = ""
    child.stdout.on("data", (c) => { stdout += c })
    child.stderr.on("data", (c) => { stderr += c })
    child.on("close", (status) => resolve({ status, stdout, stderr }))
  })
}

test("parseCalendars keeps id name subscribe, drops key", () => {
  const rows = Almanac.parseCalendars(JSON.stringify([
    { id: "cal_1", name: "Work", key: "secret", subscribe: "https://feed", write: "https://w" }
  ]))
  assert.deepEqual(rows, [{ id: "cal_1", name: "Work", subscribe: "https://feed" }])
})

test("old default names show as Agent Cloud", () => {
  const rows = Almanac.parseCalendars(JSON.stringify([
    { id: "a", name: "Almanac", key: "k" }, { id: "b", name: "Dottie", key: "k" }, { id: "c", key: "k" }
  ]))
  assert.deepEqual(rows.map((r) => r.name), ["Agent Cloud", "Agent Cloud", "Agent Cloud"])
  assert.equal(Almanac.displayName(" Home "), "Home")
})

test("isAlmanacUrl knows the Agent Cloud host and the old one", () => {
  assert.equal(Almanac.isAlmanacUrl("https://cloud.bixbyapps.com/v1/c/x/feed.ics"), true)
  assert.equal(Almanac.isAlmanacUrl("https://almanac.dottie.ai/v1/c/x/feed.ics"), true)
  assert.equal(Almanac.isAlmanacUrl("https://example.com/x.ics"), false)
})

test("errors say Agent Cloud", () => {
  assert.equal(Almanac.errorMessage(""), "Agent Cloud request failed")
  assert.equal(Almanac.errorMessage("ERROR:unauthorized"), "Agent Cloud key rejected")
})

test("eventUid reads the middle of calendarId:uid:dateKey", () => {
  assert.equal(Almanac.eventUid({
    id: "almanac:evt-abc:2026-09-21",
    calendarId: "almanac",
    dateKey: "2026-09-21"
  }), "evt-abc")
})

test("isWritable is Almanac feed or almanac id", () => {
  assert.equal(Almanac.isWritable({ calendarId: "almanac" }, []), true)
  assert.equal(Almanac.isWritable({ calendarId: "work" }, [
    { id: "work", url: "https://almanac.dottie.ai/x.ics" }
  ]), true)
  assert.equal(Almanac.isWritable({ calendarId: "work" }, [
    { id: "work", url: "https://cloud.bixbyapps.com/x.ics" }
  ]), true)
  assert.equal(Almanac.isWritable({ calendarId: "local" }, [
    { id: "local", url: "" }
  ]), false)
})

test("buildEventBody makes a timed POST body", () => {
  const result = Almanac.buildEventBody({
    title: "Dentist",
    dateKey: "2026-09-22",
    start: "09:00",
    end: "09:45",
    uid: "evt-1"
  })
  assert.equal(result.error, undefined)
  assert.equal(result.body.summary, "Dentist")
  assert.equal(result.body.uid, "evt-1")
  assert.match(result.body.start, /^2026-09-22T09:00:00/)
  assert.match(result.body.end, /^2026-09-22T09:45:00/)
})

test("buildEventBody all-day uses a date only", () => {
  const result = Almanac.buildEventBody({
    title: "Off",
    dateKey: "2026-09-22",
    allDay: true
  })
  assert.deepEqual(result.body, { summary: "Off", start: "2026-09-22", allDay: true })
})

test("almanac-events.sh posts and deletes without leaking the key", async () => {
  const seen = []
  const server = http.createServer((req, res) => {
    let raw = ""
    req.on("data", (c) => { raw += c })
    req.on("end", () => {
      seen.push({ method: req.method, url: req.url, ua: req.headers["user-agent"], auth: req.headers.authorization, body: raw })
      if (req.method === "GET") {
        res.writeHead(200, { "content-type": "application/json" })
        res.end(JSON.stringify({ id: "cal_test", feed: "plain" }))
        return
      }
      if (req.method === "POST") {
        res.writeHead(201, { "content-type": "application/json" })
        res.end(JSON.stringify({ uid: "evt-new", summary: "Call" }))
        return
      }
      res.writeHead(204)
      res.end()
    })
  })
  const port = await listen(server)
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "agentcloud-cal-"))
  const config = writeConfig(dir, port)
  const body = path.join(dir, "body.json")
  fs.writeFileSync(body, JSON.stringify({ summary: "Call", start: "2026-09-22T09:00:00-07:00" }))
  const created = await runScript(["post", "--cal", "cal_test", "--body-file", body], { ALMANAC_CONFIG: config })
  const removed = await runScript(["delete", "--cal", "cal_test", "--uid", "evt-new"], { ALMANAC_CONFIG: config })
  const feed = await runScript(["feed", "--cal", "cal_test"], { ALMANAC_CONFIG: config })
  server.close()
  fs.rmSync(dir, { recursive: true, force: true })
  assert.equal(created.status, 0, created.stderr + created.stdout)
  assert.match(created.stdout, /evt-new/)
  assert.equal(created.stdout.includes("test-key"), false)
  assert.equal(removed.status, 0, removed.stdout)
  assert.equal(seen[0].method, "GET")
  assert.equal(seen[1].method, "POST")
  assert.equal(seen[1].url, "/v1/c/cal_test/events")
  assert.equal(seen[1].auth, "Bearer " + TOKEN)
  assert.match(seen[1].ua, /agentcloud-calendar/)
  assert.equal(seen[2].method, "DELETE")
  assert.match(feed.stdout, /feed\.ics/)
})

test("almanac-events.sh seals a post when the calendar feed is seal", async () => {
  const bin = process.env.AGENTCLOUD_BIN || process.env.ALMANAC_BIN
    || ["agentcloud/target/debug/agentcloud", "almanac/target/debug/almanac"].map((rel) => path.join(process.env.HOME, "Projects", rel)).find((p) => fs.existsSync(p))
    || path.join(process.env.HOME, "Projects/agentcloud/target/debug/agentcloud")
  if (!fs.existsSync(bin)) return
  const seen = []
  const server = http.createServer((req, res) => {
    let raw = ""
    req.on("data", (c) => { raw += c })
    req.on("end", () => {
      seen.push({ method: req.method, url: req.url, body: raw })
      if (req.method === "GET") {
        res.writeHead(200, { "content-type": "application/json" })
        res.end(JSON.stringify({ id: "cal_test", feed: "seal" }))
        return
      }
      res.writeHead(201, { "content-type": "application/json" })
      res.end(raw)
    })
  })
  const port = await listen(server)
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "agentcloud-cal-"))
  const config = writeConfig(dir, port)
  const body = path.join(dir, "body.json")
  fs.writeFileSync(body, JSON.stringify({ summary: "Call", start: "2026-09-22T09:00:00-07:00" }))
  const created = await runScript(["post", "--cal", "cal_test", "--body-file", body], {
    ALMANAC_CONFIG: config,
    ALMANAC_BIN: bin
  })
  server.close()
  fs.rmSync(dir, { recursive: true, force: true })
  assert.equal(created.status, 0, created.stderr + created.stdout)
  assert.equal(seen[1].method, "PUT")
  assert.match(seen[1].url, /^\/v1\/c\/cal_test\/events\/evt-/)
  const sent = JSON.parse(seen[1].body)
  assert.match(sent.seal, /^alm1\./)
  assert.equal(seen[1].body.includes("Call"), false)
  assert.equal(created.stdout.includes("test-key"), false)
})

test("errorMessage maps the conflict line", () => {
  assert.equal(Almanac.isConflict("ERROR:conflict\n"), true)
  assert.equal(Almanac.isConflict("ERROR:not found"), false)
  assert.equal(Almanac.errorMessage("ERROR:conflict\n"), "Changed elsewhere")
})

test("sameWhen is true only when the date and times stay", () => {
  const timed = { dateKey: "2026-09-22", start: "09:00", end: "", allDay: false }
  const draft = { title: "x", dateKey: "2026-09-22", start: "09:00", end: "10:00", allDay: false }
  assert.equal(Almanac.sameWhen(timed, draft), true)
  assert.equal(Almanac.sameWhen(timed, { ...draft, dateKey: "2026-09-23" }), false)
  assert.equal(Almanac.sameWhen(timed, { ...draft, start: "09:30" }), false)
  assert.equal(Almanac.sameWhen(timed, { ...draft, allDay: true }), false)
  const allDay = { dateKey: "2026-09-22", start: "", end: "", allDay: true }
  assert.equal(Almanac.sameWhen(allDay, { ...draft, allDay: true, start: "11:00" }), true)
})

test("conflictCopy drops the uid and marks the title", () => {
  const copy = Almanac.conflictCopy({ uid: "evt-1", summary: " Dentist ", start: "2026-09-22T09:00:00-07:00", end: "2026-09-22T10:00:00-07:00" })
  assert.deepEqual(copy, { summary: "Dentist (conflict copy)", start: "2026-09-22T09:00:00-07:00", end: "2026-09-22T10:00:00-07:00" })
  assert.equal(Almanac.conflictCopy({ uid: "e", summary: "x".repeat(512), start: "2026-09-22" }).summary.length, 512)
})

test("almanac-events.sh keeps a series in place and maps a deleted event to conflict", async () => {
  const seen = []
  const server = http.createServer((req, res) => {
    req.resume()
    req.on("end", () => {
      seen.push({ method: req.method, url: req.url })
      if (req.method === "GET" && req.url === "/v1/c/cal_test") {
        res.writeHead(200, { "content-type": "application/json" })
        res.end(JSON.stringify({ id: "cal_test", feed: "plain" }))
        return
      }
      if (req.method === "GET" && req.url.endsWith("/gone")) {
        res.writeHead(404, { "content-type": "application/json" })
        res.end(JSON.stringify({ error: "not found" }))
        return
      }
      res.writeHead(200, { "content-type": "application/json" })
      res.end(JSON.stringify({ uid: "evt-1", summary: "Old", start: "2026-09-22T09:00:00", timeZone: "UTC", rrule: "FREQ=WEEKLY", rev: 9 }))
    })
  })
  const port = await listen(server)
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "agentcloud-cal-"))
  const config = writeConfig(dir, port)
  const body = path.join(dir, "body.json")
  fs.writeFileSync(body, JSON.stringify({ uid: "evt-1", summary: "New", start: "2026-09-29T09:00:00+00:00" }))
  const moved = await runScript(["post", "--cal", "cal_test", "--rev", "9", "--body-file", body], { ALMANAC_CONFIG: config })
  fs.writeFileSync(body, JSON.stringify({ uid: "gone", summary: "New" }))
  const gone = await runScript(["post", "--cal", "cal_test", "--rev", "9", "--body-file", body], { ALMANAC_CONFIG: config })
  server.close()
  fs.rmSync(dir, { recursive: true, force: true })
  assert.equal(moved.stdout, "ERROR:repeating event: only the title can change here\n")
  assert.equal(gone.stdout, "ERROR:conflict\n")
  assert.deepEqual(seen.filter((row) => row.method !== "GET"), [])
})

test("almanac-events.sh sends --rev as If-Match and maps 412 to conflict", async () => {
  const seen = []
  const server = http.createServer((req, res) => {
    req.resume()
    req.on("end", () => {
      seen.push({ method: req.method, url: req.url, ifMatch: req.headers["if-match"] })
      if (req.method === "GET" && req.url === "/v1/c/cal_test") {
        res.writeHead(200, { "content-type": "application/json" })
        res.end(JSON.stringify({ id: "cal_test", feed: "plain" }))
        return
      }
      if (req.method === "GET") {
        res.writeHead(200, { "content-type": "application/json" })
        res.end(JSON.stringify({ uid: "evt-1", summary: "Old", start: "2026-09-22T09:00:00", rrule: "FREQ=WEEKLY", rev: 9 }))
        return
      }
      res.writeHead(412, { "content-type": "application/json" })
      res.end(JSON.stringify({ error: "changed elsewhere", deleted: false, current: null }))
    })
  })
  const port = await listen(server)
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "agentcloud-cal-"))
  const config = writeConfig(dir, port)
  const body = path.join(dir, "body.json")
  fs.writeFileSync(body, JSON.stringify({ uid: "evt-1", summary: "New" }))
  const posted = await runScript(["post", "--cal", "cal_test", "--rev", "7", "--body-file", body], { ALMANAC_CONFIG: config })
  const removed = await runScript(["delete", "--cal", "cal_test", "--uid", "evt-1", "--rev", "7"], { ALMANAC_CONFIG: config })
  server.close()
  fs.rmSync(dir, { recursive: true, force: true })
  assert.equal(posted.stdout, "ERROR:conflict\n")
  assert.equal(removed.stdout, "ERROR:conflict\n")
  const writes = seen.filter((row) => row.method !== "GET")
  assert.deepEqual(writes.map((row) => [row.method, row.url, row.ifMatch]), [
    ["PUT", "/v1/c/cal_test/events/evt-1", '"7"'],
    ["DELETE", "/v1/c/cal_test/events/evt-1", '"7"']
  ])
})

test("occurrenceOf is the shown date and start, repeats reads the flag", () => {
  assert.deepEqual(Almanac.occurrenceOf({ dateKey: "2026-10-06", start: "12:00", end: "12:15" }), { date: "2026-10-06", time: "12:00" })
  assert.deepEqual(Almanac.occurrenceOf({ dateKey: "2026-10-06", start: "", allDay: true }), { date: "2026-10-06", time: "" })
  assert.equal(Almanac.repeats({ repeats: true }), true)
  assert.equal(Almanac.repeats({}), false)
})

test("almanac-events.sh skip adds the occurrence's exdate in the series zone", async () => {
  const events = {
    weekly: { uid: "weekly", summary: "Standup", start: "2026-09-22T09:00:00", end: "2026-09-22T09:15:00", timeZone: "America/Los_Angeles", rrule: "FREQ=WEEKLY", rev: 9,
      overrides: [{ recurrenceId: "2026-10-13T09:00:00", start: "2026-10-14T10:00:00", end: "2026-10-14T10:15:00" }] },
    allday: { uid: "allday", summary: "Bins", start: "2026-09-22", allDay: true, rrule: "FREQ=WEEKLY", rev: 4 },
    once: { uid: "once", summary: "Dentist", start: "2026-09-22T09:00:00-07:00", rev: 3 }
  }
  const seen = []
  const server = http.createServer((req, res) => {
    let raw = ""
    req.on("data", (c) => { raw += c })
    req.on("end", () => {
      seen.push({ method: req.method, url: req.url, ifMatch: req.headers["if-match"], body: raw })
      res.writeHead(200, { "content-type": "application/json" })
      if (req.url === "/v1/c/cal_test") return res.end(JSON.stringify({ id: "cal_test", feed: "plain" }))
      const uid = req.url.split("/")[5]
      res.end(JSON.stringify(events[uid]))
    })
  })
  const port = await listen(server)
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "agentcloud-cal-"))
  const env = { ALMANAC_CONFIG: writeConfig(dir, port), TZ: "America/New_York" }
  const run = (...args) => runScript(["skip", "--cal", "cal_test", ...args], env)
  // 09:00 in Los Angeles shows as 12:00 in New York.
  const timed = await run("--uid", "weekly", "--date", "2026-10-06", "--time", "12:00", "--rev", "9")
  const moved = await run("--uid", "weekly", "--date", "2026-10-14", "--time", "13:00", "--rev", "9")
  const allDay = await run("--uid", "allday", "--date", "2026-10-06")
  const stale = await run("--uid", "weekly", "--date", "2026-10-06", "--time", "12:00", "--rev", "8")
  const once = await run("--uid", "once", "--date", "2026-09-22", "--time", "12:00")
  server.close()
  fs.rmSync(dir, { recursive: true, force: true })
  for (const r of [timed, moved, allDay]) assert.equal(r.status, 0, r.stdout + r.stderr)
  assert.equal(stale.stdout, "ERROR:conflict\n")
  assert.equal(once.stdout, "ERROR:not a repeating event\n")
  const writes = seen.filter((row) => row.method !== "GET")
  assert.deepEqual(writes.map((row) => [row.method, row.url, row.ifMatch, JSON.parse(row.body).recurrenceId]), [
    ["PUT", "/v1/c/cal_test/events/weekly/exdates", '"9"', "2026-10-06T09:00:00"],
    ["PUT", "/v1/c/cal_test/events/weekly/exdates", '"9"', "2026-10-13T09:00:00"],
    ["PUT", "/v1/c/cal_test/events/allday/exdates", '"4"', "2026-10-06"]
  ])
})

test("almanac-events.sh ics matches a feed subscribed on the old host", async () => {
  const server = http.createServer((req, res) => {
    req.resume()
    req.on("end", () => {
      res.writeHead(200, { "content-type": "application/json" })
      res.end(JSON.stringify(req.url.indexOf("/events") >= 0 ? { events: [] } : { id: "cal_test", feed: "plain" }))
    })
  })
  const port = await listen(server)
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "agentcloud-cal-"))
  const config = path.join(dir, "hosted-calendars.json")
  fs.writeFileSync(config, JSON.stringify([{
    id: "cal_test",
    key: "test-key",
    write: `http://127.0.0.1:${port}/v1/c/cal_test/events`,
    subscribe: "https://cloud.bixbyapps.com/v1/c/cal_test/feed.ics?t=f"
  }]))
  const env = { ALMANAC_CONFIG: config }
  const old = await runScript(["ics"], env, "https://almanac.dottie.ai/v1/c/cal_test/feed.ics?t=f\n")
  const other = await runScript(["ics"], env, "https://example.com/feed.ics\n")
  server.close()
  fs.rmSync(dir, { recursive: true, force: true })
  assert.equal(old.status, 0, old.stdout + old.stderr)
  assert.match(old.stdout, /^BEGIN:VCALENDAR/)
  assert.match(old.stdout, /PRODID:-\/\/agentcloud\/\/calendar\/\/EN/)
  assert.equal(other.status, 3)
})
