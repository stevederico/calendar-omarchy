import test from "node:test"
import assert from "node:assert/strict"
import fs from "node:fs"
import os from "node:os"
import path from "node:path"
import { lib, scriptsDir, cleanEnv, sandbox, fakeSealBin, bash } from "./support/cloud_lib_harness.js"

const LOAD = `
. "$1" || exit 8
cloud_load cal_lib || exit 9
printf '%s\\n%s\\n' "$CLOUD_ID" "$CLOUD_TMPDIR"
[[ -d $CLOUD_TMPDIR ]] && echo LIVE
`

test("cloud_load sets the calendar and a temp-dir exit trap in the calling shell", async () => {
  const box = sandbox(9)
  const result = await bash([LOAD, "h", lib], box.env)
  const [id, tmp, live] = result.stdout.split("\n")
  const leftovers = fs.readdirSync(box.run)
  fs.rmSync(box.dir, { recursive: true, force: true })
  assert.equal(result.status, 0, result.stderr)
  assert.equal(id, "cal_lib")
  assert.equal(live, "LIVE")
  assert.equal(path.dirname(tmp), box.run)
  assert.deepEqual(leftovers, [])
})

test("no script calls cloud_load inside a command substitution", () => {
  const scripts = fs.readdirSync(scriptsDir).filter((f) => f.endsWith(".sh") && f !== "cloud-lib.sh")
  const texts = scripts.map((f) => [f, fs.readFileSync(path.join(scriptsDir, f), "utf8")]).filter(([, t]) => /\bcloud_load\b/.test(t))
  assert.ok(texts.length > 0)
  for (const [f, text] of texts) {
    assert.doesNotMatch(text, /\$\([^)]*\bcloud_load\b|`[^`]*\bcloud_load\b/, f)
    assert.match(text, /^cloud_load "\$CAL" \|\| fail/m, f)
  }
})

const SHOW = `. "$1"; printf '%s\\n%s\\n%s\\n' "$CLOUD_CONFIG" "$CLOUD_BASE" "$CLOUD_UA"`
const OLD = { ALMANAC_CONFIG: "/a", ALMANAC_BASE: "http://a", ALMANAC_UA: "ua-a" }
const NEW = { AGENTCLOUD_CONFIG: "/b", AGENTCLOUD_BASE: "http://b", AGENTCLOUD_UA: "ua-b" }

test("ALMANAC names and the almanac config dir are read only when the Agent Cloud ones are missing", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "agentcloud-lib-cfg-"))
  const show = async (extra) => (await bash([SHOW, "h", lib], cleanEnv({ XDG_CONFIG_HOME: dir, ...extra }))).stdout.split("\n")
  const legacy = path.join(dir, "almanac", "hosted-calendars.json")
  const current = path.join(dir, "agentcloud", "hosted-calendars.json")
  fs.mkdirSync(path.dirname(legacy), { recursive: true })
  fs.writeFileSync(legacy, "[]")
  const onlyLegacy = await show({})
  fs.mkdirSync(path.dirname(current), { recursive: true })
  fs.writeFileSync(current, "[]")
  const both = await show({})
  const oldNames = await show(OLD)
  const newNames = await show({ ...OLD, ...NEW })
  fs.rmSync(dir, { recursive: true, force: true })
  assert.equal(onlyLegacy[0], legacy)
  assert.deepEqual(both.slice(0, 2), [current, "https://cloud.bixbyapps.com"])
  assert.deepEqual(oldNames.slice(0, 3), ["/a", "http://a", "ua-a"])
  assert.deepEqual(newNames.slice(0, 3), ["/b", "http://b", "ua-b"])
})

const SEAL = `
. "$1" || exit 8
cloud_load cal_lib || exit 9
out=$(cloud_tmp) || exit 10
cloud_seal_body note n1 "$2" "$out"
printf 'RC=%s\\n' "$?"
cat "$out"
`

async function sealWith(sealBody) {
  const box = sandbox(9)
  const plain = path.join(box.dir, "plain.json")
  fs.writeFileSync(plain, JSON.stringify({ uid: "n1", rev: 3, title: "secret" }))
  const result = await bash([SEAL, "h", lib, plain], { ...box.env, AGENTCLOUD_BIN: fakeSealBin(box.dir, sealBody) })
  fs.rmSync(box.dir, { recursive: true, force: true })
  const [rc, ...rest] = result.stdout.split("\n")
  return { rc, out: rest.join("\n") }
}

test("cloud_seal_body fails without writing {\"seal\": \"\"} when the seal step fails or prints no alm1 seal", async () => {
  assert.deepEqual(await sealWith("exit 1"), { rc: "RC=1", out: "" })
  assert.deepEqual(await sealWith("printf 'not-a-seal'"), { rc: "RC=1", out: "" })
  assert.deepEqual(await sealWith("printf 'alm1.abc'"), { rc: "RC=0", out: '{"seal": "alm1.abc"}' })
})
