#!/usr/bin/env bash
# bash tests/almanac_server.sh
# Runs scripts/almanac-events.sh and `bin/sd-calendar sync` against a throwaway
# Almanac server (ALMANAC_BIN, 0.34 or later) with one plain and one sealed
# calendar. SD_CALENDAR_BIN picks another sd-calendar build. Prints TAP-ish lines.
set -u
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../scripts/almanac-events.sh"
BIN="${ALMANAC_BIN:-$HOME/Projects/almanac/target/debug/almanac}"
if [[ ! -x $BIN ]]; then
  echo "ok - skipped: no almanac binary (set ALMANAC_BIN)"
  exit 0
fi

work=$(mktemp -d)
chmod 700 "$work"
port=$((30000 + RANDOM % 20000))
AGENT_KEY=h FEED_TOKEN=f PORT=$port HOST=127.0.0.1 DB_PATH="$work/c.db" BACKUP_INTERVAL_HOURS=0 "$BIN" >/dev/null 2>&1 &
server=$!
watcher=""
trap 'kill $server ${watcher:+$watcher} 2>/dev/null; rm -rf "$work"' EXIT
for _ in $(seq 100); do curl -s -o /dev/null "http://127.0.0.1:$port/health" && break; sleep 0.05; done

fails=0
check() {
  if [[ $2 == "$3" ]]; then echo "ok - $1"; else echo "not ok - $1: got [$2] want [$3]"; fails=$((fails + 1)); fi
}

# Two calendars. Their keys and tokens go to a secrets file, never to stdout.
for feed in plain seal; do
  curl -s -H 'content-type: application/json' -H 'accept: application/json' \
    -d "{\"feed\":\"$feed\"}" "http://127.0.0.1:$port/calendars" >"$work/$feed.json"
done
python3 - "$work" <<'PY'
import hashlib, json, os, sys
work = sys.argv[1]
rows, secrets = [], []
for feed in ("plain", "seal"):
    c = json.load(open(os.path.join(work, feed + ".json")))
    rows.append({"id": c["id"], "name": feed, "key": c["key"], "write": c["write"], "subscribe": c["subscribe"]})
    secrets += [c["key"], hashlib.sha256((c["key"] + "almanac-auth-v1").encode()).hexdigest()]
    open(os.path.join(work, feed + ".id"), "w").write(c["id"])
json.dump(rows, open(os.path.join(work, "creds.json"), "w"))
open(os.path.join(work, "secrets"), "w").write("\n".join(secrets) + "\n")
PY
chmod 600 "$work/creds.json" "$work/secrets"

# curl that records its argv, so the test sees what `ps` would.
mkdir -p "$work/bin" "$work/run"
chmod 700 "$work/run"
real_curl=$(command -v curl)
cat >"$work/bin/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$work/curl-argv.log"
exec "$real_curl" "\$@"
EOF
chmod +x "$work/bin/curl"

touch "$work/watch"
(while [[ -e $work/watch ]]; do ps -eo args >>"$work/ps.log" 2>/dev/null; done) &
watcher=$!

run() {
  PATH="$work/bin:$PATH" XDG_RUNTIME_DIR="$work/run" ALMANAC_CONFIG="$work/creds.json" ALMANAC_BIN="$BIN" \
    bash "$script" "$@" <"${RUN_STDIN:-/dev/null}" >"$work/out" 2>"$work/err"
  local status=$?
  cat "$work/out" >>"$work/all-out"
  return $status
}
field() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2], {}, {"d": d}))' "$work/out" "$1" 2>/dev/null; }

day() { date -d "$1" +%Y-%m-%d; }
at() { printf '%sT%s%s' "$1" "$2" "$(date -d "$1 $2" +%:z)"; }
d1=$(day "+3 days")
d2=$(day "+10 days")
series_start=$(day "-1 day")
skip=$(day "+6 days")
sub() { python3 -c 'import json,sys; print([r["subscribe"] for r in json.load(open(sys.argv[1])) if r["name"] == sys.argv[2]][0])' "$work/creds.json" "$1"; }

# A weekly series at 09:00 Los Angeles; its second date is the one skipped.
week1=$(day "+1 day")
week2=$(day "+8 days")
week3=$(day "+15 days")
# A Los Angeles wall clock as the calendar shows it: local "YYYY-MM-DD HH:MM".
shown() {
  python3 -c 'import sys; from datetime import datetime; from zoneinfo import ZoneInfo
print(datetime.fromisoformat(sys.argv[1]).replace(tzinfo=ZoneInfo("America/Los_Angeles")).astimezone().strftime("%Y-%m-%d %H:%M"))' "$1"
}
# The exdates GET changes reports for one event, opened when sealed.
changes_exdates() {
  ALMANAC_CREDS="$work/creds.json" python3 - "$work/creds.json" "$1" "$2" "$BIN" <<'PY'
import hashlib, json, subprocess, sys, urllib.request
creds, name, uid, binary = sys.argv[1:]
row = [r for r in json.load(open(creds)) if r["name"] == name][0]
token = hashlib.sha256((row["key"] + "almanac-auth-v1").encode()).hexdigest()
url = row["write"].rsplit("/events", 1)[0] + "/changes?since=0"
req = urllib.request.Request(url, headers={"Authorization": "Bearer " + token})
events = json.load(urllib.request.urlopen(req))["events"]
ev = [e for e in events if e["uid"] == uid][0]
if ev.get("seal"):
    plain = subprocess.run([binary, "open", "--cal", row["id"], "--kind", "event", "--uid", uid],
                           input=ev["seal"].encode(), capture_output=True, check=True).stdout
    ev = json.loads(plain)
print(ev.get("exdates"))
PY
}

for feed in plain seal; do
  cal=$(cat "$work/$feed.id")
  printf '{"summary":"Dentist","start":"%s","end":"%s"}' "$(at "$d1" 09:00:00)" "$(at "$d1" 09:45:00)" >"$work/body.json"
  run post --cal "$cal" --body-file "$work/body.json"
  check "$feed: post" "$?" "0"
  uid=$(field 'd["uid"]')
  rev=$(field 'd["rev"]')
  check "$feed: post prints the event" "$(field 'd["summary"]')" "Dentist"

  # A daily series with a place, a time zone and a skipped day, made with a chosen uid.
  printf '{"uid":"standup","summary":"Standup","start":"%sT09:00:00","end":"%sT09:15:00","timeZone":"America/Los_Angeles","rrule":"FREQ=DAILY","location":"Room 4"}' "$series_start" "$series_start" >"$work/body.json"
  run post --cal "$cal" --body-file "$work/body.json"
  check "$feed: post with a new uid creates" "$(field 'd["uid"]')" "standup"
  srev=$(field 'd["rev"]')

  # The editor shows one date of a series: its times would move the whole series.
  printf '{"uid":"standup","summary":"Standup v2","start":"%sT10:00:00","end":"%sT10:15:00"}' "$skip" "$skip" >"$work/body.json"
  run post --cal "$cal" --rev "$srev" --body-file "$work/body.json"
  check "$feed: series times are refused" "$(cat "$work/out")" "ERROR:repeating event: only the title can change here"

  # A title-only edit sends summary alone; the update keeps the rest.
  printf '{"uid":"standup","summary":"Standup v2"}' >"$work/body.json"
  run post --cal "$cal" --rev "$srev" --body-file "$work/body.json"
  check "$feed: update with rev" "$?" "0"
  check "$feed: update keeps fields" "$(field '(d["summary"], d.get("rrule"), d.get("location"), d.get("timeZone"), d["start"][:10])')" "('Standup v2', 'FREQ=DAILY', 'Room 4', 'America/Los_Angeles', '$series_start')"
  srev2=$(field 'd["rev"]')
  run post --cal "$cal" --rev "$srev" --body-file "$work/body.json"
  check "$feed: stale rev update is a conflict" "$(cat "$work/out")" "ERROR:conflict"
  run delete --cal "$cal" --uid standup --rev "$srev"
  check "$feed: stale rev delete is a conflict" "$(cat "$work/out")" "ERROR:conflict"

  run list --cal "$cal"
  check "$feed: list" "$(field 'sorted(e["summary"] for e in d["events"])')" "['Dentist', 'Standup v2']"

  sub "$feed" >"$work/url"
  RUN_STDIN="$work/url" run ics
  check "$feed: ics" "$?" "0"
  check "$feed: ics has the events" "$(grep -c '^SUMMARY:\(Dentist\|Standup v2\)' "$work/out")" "2"
  check "$feed: ics has revs" "$(grep -c "^X-ALMANAC-REV:\($rev\|$srev2\)" "$work/out")" "2"
  check "$feed: ics keeps the rule" "$(grep -c '^RRULE:FREQ=DAILY' "$work/out")" "1"

  printf '{"summary":"Dentist","start":"%s"}' "$(at "$d2" 09:00:00)" >"$work/body.json"
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["uid"]=sys.argv[2]; json.dump(d, open(sys.argv[1],"w"))' "$work/body.json" "$uid"
  run post --cal "$cal" --rev "$rev" --body-file "$work/body.json"
  check "$feed: move with rev" "$(field 'd["start"][:10]')" "$d2"
  drev=$(field 'd["rev"]')
  run delete --cal "$cal" --uid "$uid" --rev "$drev"
  check "$feed: delete with rev" "$(cat "$work/out")" '{"ok":true}'
  run post --cal "$cal" --rev "$drev" --body-file "$work/body.json"
  check "$feed: update of a deleted event is a conflict" "$(cat "$work/out")" "ERROR:conflict"

  # Delete one date of a weekly series: an exdate on that uid, the rest stays.
  printf '{"uid":"weekly","summary":"Weekly","start":"%sT09:00:00","end":"%sT09:30:00","timeZone":"America/Los_Angeles","rrule":"FREQ=WEEKLY"}' "$week1" "$week1" >"$work/body.json"
  run post --cal "$cal" --body-file "$work/body.json"
  wrev=$(field 'd["rev"]')
  read -r skip_d skip_t <<<"$(shown "${week2}T09:00:00")"
  run skip --cal "$cal" --uid weekly --date "$skip_d" --time "$skip_t" --rev "$wrev"
  check "$feed: skip one date" "$?" "0"
  check "$feed: skip adds the exdate, keeps the rule" "$(field '(d.get("exdates"), d.get("rrule"), d["start"][:10])')" "(['${week2}T09:00:00'], 'FREQ=WEEKLY', '$week1')"
  run skip --cal "$cal" --uid weekly --date "$skip_d" --time "$skip_t" --rev "$wrev"
  check "$feed: stale rev skip is a conflict" "$(cat "$work/out")" "ERROR:conflict"
  run list --cal "$cal"
  check "$feed: the series is still there" "$(field '[(e.get("exdates"), e.get("rrule")) for e in d["events"] if e["uid"] == "weekly"]')" "[(['${week2}T09:00:00'], 'FREQ=WEEKLY')]"
  RUN_STDIN="$work/url" run ics
  check "$feed: ics skips that date" "$(grep -c "^EXDATE;VALUE=DATE:${skip_d//-/}" "$work/out")" "1"
  check "$feed: changes show the exdate" "$(changes_exdates "$feed" weekly)" "['${week2}T09:00:00']"
done

# A plain feed drops exactly that occurrence, in the series' zone.
check "plain: feed has the exdate" "$(curl -s "$(sub plain)" | grep -c "^EXDATE;TZID=America/Los_Angeles:${week2//-/}T090000")" "1"
check "seal: feed shows only the seal" "$(curl -s "$(sub seal)" | grep -c '^EXDATE')" "0"

printf 'https://example.com/other.ics\n' >"$work/url"
RUN_STDIN="$work/url" run ics
check "ics on another feed exits 3" "$?" "3"
run list --cal nope
check "unknown calendar" "$(cat "$work/out")" "ERROR:No Almanac calendar"

# bin/sd-calendar syncs both calendars through the script, not the ICS feed.
cal_bin="${SD_CALENDAR_BIN:-$here/../bin/sd-calendar}"
export XDG_STATE_HOME="$work/state"
# A build outside bin/ cannot find ../scripts on its own.
[[ -n ${SD_CALENDAR_BIN-} ]] && export SD_CALENDAR_ALMANAC_SCRIPT="$script"
sd() { PATH="$work/bin:$PATH" XDG_RUNTIME_DIR="$work/run" ALMANAC_CONFIG="$work/creds.json" ALMANAC_BIN="$BIN" "$cal_bin" "$@" >"$work/out" 2>"$work/err"; }
for feed in plain seal; do
  sd subscribe "$feed" "$(sub "$feed")"
  check "sd-calendar subscribe $feed" "$?" "0"
done
sd sync
check "sd-calendar sync" "$(grep -cE '^synced [0-9]+ events$' "$work/out")" "1"
store="$work/state/omarchy/sd-calendar.json"
check "store is 0600" "$(stat -c %a "$store")" "600"
check "store dir is 0700" "$(stat -c %a "$work/state/omarchy")" "700"
check "sealed and plain series synced, skipped none" "$(python3 -c 'import json,sys
d = json.load(open(sys.argv[1]))
rows = [e for e in d["events"] if e["title"] == "Standup v2"]
print(sorted({e["calendarId"] for e in rows}), all(e.get("rev") for e in rows), len(rows) > 20, rows[0]["start"] != "")' "$store")" "['plain', 'seal'] True True True"
check "the feed URL never reached curl" "$(grep -c '/feed/' "$work/curl-argv.log")" "0"
read -r w1 _ <<<"$(shown "${week1}T09:00:00")"
read -r w2 _ <<<"$(shown "${week2}T09:00:00")"
read -r w3 _ <<<"$(shown "${week3}T09:00:00")"
check "the skipped date is gone, the others stay, all marked repeating" "$(python3 -c 'import json,sys
d = json.load(open(sys.argv[1]))
for cal in ("plain", "seal"):
    rows = [e for e in d["events"] if e["title"] == "Weekly" and e["calendarId"] == cal]
    keys = {e["dateKey"] for e in rows}
    print(cal, sys.argv[2] in keys, sys.argv[3] in keys, sys.argv[4] in keys, all(e.get("repeats") for e in rows))' "$store" "$w1" "$w2" "$w3" | tr '\n' ' ')" "plain True False True True seal True False True True "

# Deleting all dates still deletes the series.
for feed in plain seal; do
  cal=$(cat "$work/$feed.id")
  run list --cal "$cal"
  wrev=$(field '[e["rev"] for e in d["events"] if e["uid"] == "weekly"][0]')
  run delete --cal "$cal" --uid weekly --rev "$wrev"
  check "$feed: delete all dates" "$(cat "$work/out")" '{"ok":true}'
  run list --cal "$cal"
  check "$feed: the series is gone" "$(field '[e for e in d["events"] if e["uid"] == "weekly"]')" "[]"
done

rm -f "$work/watch"
wait "$watcher" 2>/dev/null
watcher=""

check "ps saw the script run" "$(grep -c 'almanac-events.sh' "$work/ps.log" | awk '{print ($1 > 0) ? "yes" : "no"}')" "yes"
check "no key or token in ps" "$(grep -cF -f "$work/secrets" "$work/ps.log")" "0"
check "curl ran through the wrapper" "$(awk 'END {print (NR > 0) ? "yes" : "no"}' "$work/curl-argv.log")" "yes"
check "no key or token in curl argv" "$(grep -cF -f "$work/secrets" "$work/curl-argv.log")" "0"
check "no key or token on stdout" "$(grep -cF -f "$work/secrets" "$work/all-out")" "0"
check "temp files removed" "$(find "$work/run" -mindepth 1 | wc -l | tr -d ' ')" "0"

# The sealed event never reached the server as plaintext; a plain one does.
printf '{"summary":"sealed words","start":"%s"}' "$d1" >"$work/body.json"
run post --cal "$(cat "$work/seal.id")" --body-file "$work/body.json"
check "sealed post opens" "$(field 'd["sealed"]')" "True"
printf '{"summary":"plain words","start":"%s"}' "$d1" >"$work/body.json"
run post --cal "$(cat "$work/plain.id")" --body-file "$work/body.json"
check "server stores only the seal" "$(cat "$work"/c.db* | grep -ac 'sealed words')" "0"
check "server stores plain text for a plain calendar" "$(cat "$work"/c.db* | grep -ac 'plain words' | awk '{print ($1 > 0) ? "yes" : "no"}')" "yes"

exit $fails
