import test from "node:test"
import assert from "node:assert/strict"
import fs from "node:fs"
import http from "node:http"
import path from "node:path"
import { lib, KEY, TOKEN, sandbox, bash, listen, bearer, CURL_TWICE } from "./support/cloud_lib_harness.js"

async function runAgainst(handler, args) {
  const seen = []
  const server = http.createServer((req, res) => {
    let raw = ""
    req.on("data", (c) => { raw += c })
    req.on("end", () => {
      seen.push({ method: req.method, url: req.url, who: bearer(req), ifMatch: req.headers["if-match"], body: raw })
      const code = handler(req, bearer(req))
      res.writeHead(code, { "content-type": "application/json" })
      res.end("{}")
    })
  })
  const port = await listen(server)
  const box = sandbox(port)
  const body = path.join(box.dir, "body.json")
  fs.writeFileSync(body, JSON.stringify({ title: "x" }))
  const result = await bash([CURL_TWICE, "h", lib, ...args.map((a) => (a === "@body" ? body : a))], box.env, true)
  server.close()
  const argv = fs.readFileSync(box.argvLog, "utf8")
  const leftovers = fs.readdirSync(box.run)
  fs.rmSync(box.dir, { recursive: true, force: true })
  return { result, seen, argv, leftovers }
}

function assertNoSecretLeak(run) {
  assert.match(run.argv, /-K -/)
  assert.equal(run.argv.includes(TOKEN), false, "token reached curl argv")
  assert.equal(run.argv.includes(KEY), false, "key reached curl argv")
  assert.equal(run.result.stderr.includes(KEY), false, "raw key showed up in a bash trace")
}

test("cloud_curl sends sha256(key + almanac-auth-v1) as the bearer on curl stdin, never in argv or a traced variable", async () => {
  const run = await runAgainst((_req, who) => (who === "token" ? 200 : 401), ["PUT", "@body", "7"])
  assert.equal(run.result.status, 0, run.result.stderr)
  assert.equal(run.result.stdout, "CODE=200\nCODE=200\n")
  assert.deepEqual(run.seen.map((r) => [r.method, r.url, r.who, r.ifMatch]), [
    ["PUT", "/v1/c/cal_lib/todos", "token", '"7"'],
    ["GET", "/v1/c/cal_lib/todos", "token", undefined]
  ])
  assert.equal(run.seen[0].body, '{"title":"x"}')
  assertNoSecretLeak(run)
  assert.deepEqual(run.leftovers, [])
})

function teachingServer(learns) {
  let taught = false
  return (req, who) => {
    if (who === "key" && req.url === "/v1/c/cal_lib") {
      taught = learns
      return 200
    }
    return who === "token" && taught ? 200 : 401
  }
}

const row = (url, who) => ["GET", url, who]
const TODOS = "/v1/c/cal_lib/todos"
const ROOT = "/v1/c/cal_lib"

test("a 401 teaches the token with one raw-key request on stdin and retries that call once", async () => {
  const learned = await runAgainst(teachingServer(true), ["GET", "", ""])
  assert.equal(learned.result.stdout, "CODE=200\nCODE=200\n")
  assert.deepEqual(learned.seen.map((r) => [r.method, r.url, r.who]),
    [row(TODOS, "token"), row(ROOT, "key"), row(TODOS, "token"), row(TODOS, "token")])
  assertNoSecretLeak(learned)
  const refused = await runAgainst(teachingServer(false), ["GET", "", ""])
  assert.equal(refused.result.stdout, "CODE=401\nCODE=401\n")
  assert.deepEqual(refused.seen.map((r) => [r.method, r.url, r.who]),
    [row(TODOS, "token"), row(ROOT, "key"), row(TODOS, "token"), row(TODOS, "token"), row(ROOT, "key"), row(TODOS, "token")])
  assertNoSecretLeak(refused)
})
