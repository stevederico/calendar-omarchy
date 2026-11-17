import fs from "node:fs"
import os from "node:os"
import path from "node:path"
import crypto from "node:crypto"
import { spawn, spawnSync } from "node:child_process"

export const lib = path.join(import.meta.dirname, "..", "..", "scripts", "cloud-lib.sh")
export const scriptsDir = path.join(import.meta.dirname, "..", "..", "scripts")
export const KEY = "lib-test-key-4f1c9a"
export const WIRE = "almanac-auth-v1"
export const TOKEN = crypto.createHash("sha256").update(KEY + WIRE).digest("hex")
const REAL_CURL = spawnSync("bash", ["-c", "command -v curl"], { encoding: "utf8" }).stdout.trim()

export function cleanEnv(extra) {
  const kept = Object.entries(process.env).filter(([k]) => !/^(CLOUD|AGENTCLOUD|ALMANAC)_/.test(k) && k !== "XDG_CONFIG_HOME")
  return { ...Object.fromEntries(kept), ...extra }
}

export function sandbox(port) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "agentcloud-lib-"))
  const run = path.join(dir, "run")
  const bin = path.join(dir, "bin")
  fs.mkdirSync(run, { mode: 0o700 })
  fs.mkdirSync(bin)
  const argvLog = path.join(dir, "curl-argv.log")
  const shim = ["#!/usr/bin/env bash", `printf '%s\\n' "$*" >>"${argvLog}"`, `exec "${REAL_CURL}" "$@"`, ""]
  fs.writeFileSync(path.join(bin, "curl"), shim.join("\n"), { mode: 0o755 })
  const config = path.join(dir, "hosted-calendars.json")
  const write = `http://127.0.0.1:${port}/v1/c/cal_lib/events`
  fs.writeFileSync(config, JSON.stringify([{ id: "cal_lib", name: "Lib", key: KEY, write }]))
  const env = cleanEnv({ PATH: bin + ":" + process.env.PATH, XDG_RUNTIME_DIR: run, CLOUD_CONFIG: config })
  return { dir, run, bin, config, argvLog, env }
}

export function fakeSealBin(dir, sealBody) {
  const file = path.join(dir, "fake-agentcloud")
  const lines = ["#!/usr/bin/env bash", `wire=${WIRE}`, "if [[ $1 == seal ]]; then", "  cat >/dev/null", "  " + sealBody, "fi", ""]
  fs.writeFileSync(file, lines.join("\n"), { mode: 0o755 })
  return file
}

export function bash(args, env, trace) {
  return new Promise((resolve) => {
    const child = spawn("bash", [...(trace ? ["-x"] : []), "-c", ...args], { env })
    let stdout = ""
    let stderr = ""
    child.stdout.on("data", (c) => { stdout += c })
    child.stderr.on("data", (c) => { stderr += c })
    child.stdin.end()
    child.on("close", (status) => resolve({ status, stdout, stderr }))
  })
}

export function listen(server) {
  return new Promise((resolve, reject) => {
    server.listen(0, "127.0.0.1", () => resolve(server.address().port))
    server.on("error", reject)
  })
}

export function bearer(req) {
  const auth = String(req.headers.authorization || "")
  if (auth === "Bearer " + TOKEN) return "token"
  if (auth === "Bearer " + KEY) return "key"
  return auth || "none"
}

export const CURL_TWICE = `
. "$1" || exit 8
cloud_load cal_lib || exit 9
out=$(cloud_tmp) || exit 10
printf 'CODE=%s\\n' "$(cloud_curl "$2" "$CLOUD_ROOT/todos" "$out" "$3" "$4")"
printf 'CODE=%s\\n' "$(cloud_curl GET "$CLOUD_ROOT/todos" "$out")"
`
