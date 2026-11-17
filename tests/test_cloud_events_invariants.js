import test from "node:test"
import assert from "node:assert/strict"
import fs from "node:fs"
import http from "node:http"
import os from "node:os"
import path from "node:path"
import { spawn } from "node:child_process"

const script = path.join(import.meta.dirname, "..", "scripts", "cloud-events.sh")

function writeConfig(dir, port) {
  const config = path.join(dir, "hosted-calendars.json")
  const write = `http://127.0.0.1:${port}/v1/c/cal_test/events`
  fs.writeFileSync(config, JSON.stringify([{ id: "cal_test", name: "Test", key: "test-key", write }]))
  return config
}

function listen(server) {
  return new Promise((resolve) => {
    server.listen(0, "127.0.0.1", () => resolve(server.address().port))
  })
}

function runScript(args, env) {
  return new Promise((resolve) => {
    const child = spawn("bash", [script, ...args], { env: { ...process.env, ...env } })
    child.stdin.end()
    let stdout = ""
    let stderr = ""
    child.stdout.on("data", (c) => { stdout += c })
    child.stderr.on("data", (c) => { stderr += c })
    child.on("close", (status) => resolve({ status, stdout, stderr }))
  })
}

function fakeSealBin(dir) {
  const file = path.join(dir, "fake-agentcloud")
  fs.writeFileSync(file, [
    "#!/usr/bin/env bash",
    "wire=almanac-auth-v1",
    "case \"$1\" in",
    "  seal) printf 'alm1.'; base64 -w0 ;;",
    "  open) cut -c6- | base64 -d ;;",
    "esac",
    ""
  ].join("\n"), { mode: 0o755 })
  return file
}

const sealOf = (obj) => "alm1." + Buffer.from(JSON.stringify(obj)).toString("base64")
const openSeal = (seal) => JSON.parse(Buffer.from(String(seal).slice(5), "base64").toString())

test("cloud-events.sh skip on a sealed calendar puts the exdate inside the seal with If-Match, never the exdates route", async () => {
  const series = { summary: "Standup", start: "2026-09-22T09:00:00", end: "2026-09-22T09:15:00", timeZone: "UTC", rrule: "FREQ=WEEKLY" }
  const seen = []
  const server = http.createServer((req, res) => {
    let raw = ""
    req.on("data", (c) => { raw += c })
    req.on("end", () => {
      seen.push({ method: req.method, url: req.url, ifMatch: req.headers["if-match"], body: raw })
      res.writeHead(200, { "content-type": "application/json" })
      if (req.url === "/v1/c/cal_test") return res.end(JSON.stringify({ id: "cal_test", feed: "seal" }))
      if (req.method === "GET") return res.end(JSON.stringify({ uid: "weekly", rev: 9, seal: sealOf(series) }))
      res.end(JSON.stringify({ uid: "weekly", rev: 10, seal: JSON.parse(raw).seal }))
    })
  })
  const port = await listen(server)
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "agentcloud-cal-"))
  const env = { CLOUD_CONFIG: writeConfig(dir, port), AGENTCLOUD_BIN: fakeSealBin(dir), TZ: "UTC" }
  const run = (...args) => runScript(["skip", "--cal", "cal_test", "--uid", "weekly", "--date", "2026-10-06", "--time", "09:00", ...args], env)
  const skipped = await run("--rev", "9")
  const stale = await run("--rev", "8")
  server.close()
  fs.rmSync(dir, { recursive: true, force: true })
  assert.equal(skipped.status, 0, skipped.stdout + skipped.stderr)
  assert.equal(stale.stdout, "ERROR:conflict\n")
  const writes = seen.filter((row) => row.method !== "GET")
  assert.deepEqual(writes.map((row) => [row.method, row.url, row.ifMatch]), [["PUT", "/v1/c/cal_test/events/weekly", '"9"']])
  const sent = JSON.parse(writes[0].body)
  assert.deepEqual(Object.keys(sent), ["seal"])
  const opened = openSeal(sent.seal)
  assert.deepEqual(opened.exdates, ["2026-10-06T09:00:00"])
  assert.equal(opened.rrule, "FREQ=WEEKLY")
  assert.equal(opened.start, series.start)
})

test("cloud-events.sh updates with a PUT of the merged event at the server's rev, never PATCH", async () => {
  const current = { uid: "evt-1", summary: "Old", start: "2026-09-22T09:00:00", end: "2026-09-22T10:00:00", timeZone: "UTC", location: "Room 4", rev: 9 }
  const seen = []
  const server = http.createServer((req, res) => {
    let raw = ""
    req.on("data", (c) => { raw += c })
    req.on("end", () => {
      seen.push({ method: req.method, url: req.url, ifMatch: req.headers["if-match"], body: raw })
      res.writeHead(200, { "content-type": "application/json" })
      if (req.url === "/v1/c/cal_test") return res.end(JSON.stringify({ id: "cal_test", feed: "plain" }))
      if (req.method === "GET") return res.end(JSON.stringify(current))
      res.end(JSON.stringify({ ...JSON.parse(raw), uid: "evt-1", rev: 10 }))
    })
  })
  const port = await listen(server)
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "agentcloud-cal-"))
  const body = path.join(dir, "body.json")
  fs.writeFileSync(body, JSON.stringify({ uid: "evt-1", summary: "New" }))
  const result = await runScript(["post", "--cal", "cal_test", "--body-file", body], { CLOUD_CONFIG: writeConfig(dir, port) })
  server.close()
  fs.rmSync(dir, { recursive: true, force: true })
  assert.equal(result.status, 0, result.stdout + result.stderr)
  const writes = seen.filter((row) => row.method !== "GET")
  assert.deepEqual(writes.map((row) => [row.method, row.url, row.ifMatch]), [["PUT", "/v1/c/cal_test/events/evt-1", '"9"']])
  assert.deepEqual(JSON.parse(writes[0].body), {
    summary: "New", start: current.start, end: current.end, timeZone: "UTC", location: "Room 4"
  })
})
