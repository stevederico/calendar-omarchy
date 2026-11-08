#!/usr/bin/env bash
# Talk to Agent Cloud hosted events through almanac-lib.sh.
# The key stays in the config file; requests carry its token on curl's stdin.
#
#   list                               events as JSON, sealed ones opened
#   post   --body-file FILE [--rev N]  a body with a uid updates that event
#   delete --uid UID [--rev N]         the event, or every date of a series
#   skip   --uid UID --date YYYY-MM-DD [--time HH:MM] [--rev N]
#                                      one date of a repeating event
#   feed                             the calendar's subscribe URL
#   ics                                read a subscribe URL on stdin; print that
#                                      calendar's events as ICS (exit 3: not Agent Cloud)
#
# An update keeps the fields the editor does not own (location, description,
# repeat rule, time zone, skipped and moved dates). An update of a repeating
# event may change its title only: the editor shows one date, and its times
# would move the whole series. Prints JSON on success, `ERROR:<text>`
# otherwise. A stale --rev, or one for an event deleted since, prints
# `ERROR:conflict`.
#
# skip takes the date and start time the calendar shows (local time) and adds
# that occurrence's recurrence id to the event's exdates: the series' wall
# clock in its time zone, or YYYY-MM-DD when all-day, so the feed drops exactly
# that date. A moved date (override) is skipped by its own recurrence id. A
# plain calendar uses the exdates route. A sealed calendar's server refuses
# that route and cannot read the event, so there the exdate lives inside the
# seal: open, add, seal again, PUT with If-Match.
set -u

fail() {
  printf 'ERROR:%s\n' "$1"
  exit 1
}

ALMANAC_UA="${ALMANAC_UA:-Mozilla/5.0 agentcloud-calendar}"
# shellcheck source=almanac-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/almanac-lib.sh" || fail "Agent Cloud library missing"

CMD=""
CAL=""
ITEM=""
BODYFILE=""
REV=""
DATE=""
TIME=""

while (( $# > 0 )); do
  case "$1" in
    list|post|delete|skip|feed|ics)
      [[ -z $CMD ]] || fail "usage"
      CMD="$1"
      shift
      ;;
    --cal) CAL="${2-}"; shift 2 ;;
    --uid) ITEM="${2-}"; shift 2 ;;
    --body-file) BODYFILE="${2-}"; shift 2 ;;
    --rev) REV="${2-}"; shift 2 ;;
    --date) DATE="${2-}"; shift 2 ;;
    --time) TIME="${2-}"; shift 2 ;;
    -*) fail "unknown option" ;;
    *) fail "usage" ;;
  esac
done

[[ -n $CMD ]] || fail "usage"
if [[ $CMD == post ]]; then
  [[ -n $BODYFILE && -f $BODYFILE ]] || fail "body file required"
fi
if [[ $CMD == delete || $CMD == skip ]]; then
  [[ -n $ITEM ]] || fail "uid required"
fi
if [[ $CMD == skip ]]; then
  [[ $DATE =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || fail "date required"
  [[ -z $TIME || $TIME =~ ^[0-9]{2}:[0-9]{2}$ ]] || fail "bad time"
fi
[[ -z $REV || $REV =~ ^[0-9]+$ ]] || fail "bad rev"

# Which calendar a subscribe URL belongs to. Reads ids and URLs only. A feed
# subscribed on the old almanac.dottie.ai host matches its Agent Cloud URL.
calendar_for_url() {
  [[ -f $ALMANAC_CONFIG ]] || return 1
  python3 -c 'import json, sys
def norm(u):
    u = str(u or "").strip()
    for p in ("webcal://", "webcals://"):
        if u.startswith(p):
            u = "https://" + u[len(p):]
    if u.startswith("https://almanac.dottie.ai/"):
        u = "https://cloud.bixbyapps.com/" + u[len("https://almanac.dottie.ai/"):]
    return u.rstrip("/")
want = norm(sys.stdin.readline())
try:
    raw = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
rows = raw if isinstance(raw, list) else raw.get("calendars", [raw]) if isinstance(raw, dict) else []
for row in rows:
    if isinstance(row, dict) and row.get("id") and want and norm(row.get("subscribe")) == want:
        print(row["id"])
        sys.exit(0)
sys.exit(1)' "$ALMANAC_CONFIG"
}

if [[ $CMD == ics ]]; then
  CAL=$(calendar_for_url) || { printf 'ERROR:not agent cloud\n'; exit 3; }
fi

if [[ $CMD == feed ]]; then
  [[ -f $ALMANAC_CONFIG ]] || fail "No Agent Cloud calendar"
  SUBSCRIBE=$(ALMANAC_WANT="$CAL" python3 -c 'import json, os, sys
raw = json.load(open(sys.argv[1]))
rows = raw if isinstance(raw, list) else raw.get("calendars", [raw]) if isinstance(raw, dict) else []
want = os.environ["ALMANAC_WANT"]
for row in rows:
    if isinstance(row, dict) and row.get("id") and row.get("key") and (not want or row["id"] == want):
        print(row.get("subscribe") or "")
        break' "$ALMANAC_CONFIG" 2>/dev/null) || fail "No Agent Cloud calendar"
  [[ -n $SUBSCRIBE ]] || fail "No Agent Cloud feed"
  printf '%s\n' "$SUBSCRIBE"
  exit 0
fi

almanac_load "$CAL" || fail "No Agent Cloud calendar"
EVENTS="$ALMANAC_ROOT/events"
OUT=$(almanac_tmp) || fail "Agent Cloud request failed"
CODE=""

# request METHOD URL [BODY_FILE] [IF_MATCH_REV]
request() {
  CODE=$(almanac_curl "$1" "$2" "$OUT" "${3-}" "${4-}") || fail "Agent Cloud request failed"
}

# Print the reply, opened. Map errors to ERROR: lines.
finish() {
  local err
  case "$CODE" in
    200|201)
      if [[ ! -s $OUT ]]; then
        printf '%s\n' '{"ok":true}'
      else
        almanac_open event <"$OUT" || fail "sealed calendar needs the agentcloud or almanac binary"
      fi
      exit 0
      ;;
    204)
      printf '%s\n' '{"ok":true}'
      exit 0
      ;;
    412) fail "conflict" ;;
  esac
  err=$(almanac_error "$OUT")
  case "$CODE" in
    400) fail "${err:-bad event}" ;;
    401) fail "${err:-Agent Cloud key rejected}" ;;
    403) fail "${err:-Agent Cloud blocked}" ;;
    404) fail "${err:-not found}" ;;
    409) fail "${err:-calendar is full}" ;;
    429) fail "${err:-rate limit exceeded}" ;;
  esac
  fail "${err:-Agent Cloud HTTP ${CODE}}"
}

# Events as ICS for bin/sd-calendar: local wall-clock times, X-ALMANAC-REV.
to_ics() {
  python3 -c 'import json, sys
from datetime import date, datetime, timezone
try:
    from zoneinfo import ZoneInfo
except Exception:
    ZoneInfo = None

def local(value, tz):
    """A start or end as (YYYYMMDD, HHMMSS or "") in local time."""
    text = str(value or "").strip()
    if not text:
        return None
    if len(text) == 10:
        return text.replace("-", ""), ""
    try:
        dt = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None
    if dt.tzinfo is None and tz and ZoneInfo:
        try:
            dt = dt.replace(tzinfo=ZoneInfo(tz))
        except Exception:
            pass
    if dt.tzinfo is not None:
        dt = dt.astimezone()
    return dt.strftime("%Y%m%d"), dt.strftime("%H%M%S")

def esc(s):
    return str(s or "").replace("\\", "\\\\").replace(";", "\\;").replace(",", "\\,").replace("\n", "\\n")

def dt_lines(start, end, all_day):
    out = []
    if not start:
        return out
    if all_day or not start[1]:
        out.append("DTSTART;VALUE=DATE:" + start[0])
        if end:
            out.append("DTEND;VALUE=DATE:" + end[0])
    else:
        out.append("DTSTART:%sT%s" % start)
        if end and end[1]:
            out.append("DTEND:%sT%s" % end)
    return out

data = json.load(sys.stdin)
lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//agentcloud//calendar//EN"]
for ev in data.get("events") or []:
    if not isinstance(ev, dict) or ev.get("unreadable") or not ev.get("uid"):
        continue
    tz = ev.get("timeZone") or ""
    all_day = bool(ev.get("allDay"))
    start = local(ev.get("start"), tz)
    if not start:
        continue
    rev = str(ev.get("rev") or "")
    head = ["BEGIN:VEVENT", "UID:" + str(ev["uid"]), "SUMMARY:" + esc(ev.get("summary") or "Untitled")]
    if rev:
        head.append("X-ALMANAC-REV:" + rev)
    body = dt_lines(start, local(ev.get("end"), tz), all_day)
    if ev.get("rrule"):
        body.append("RRULE:" + str(ev["rrule"]))
    skipped = [local(x, tz) for x in ev.get("exdates") or []]
    moved = [o for o in ev.get("overrides") or [] if isinstance(o, dict)]
    skipped += [local(o.get("recurrenceId"), tz) for o in moved]
    for day in skipped:
        if day:
            body.append("EXDATE;VALUE=DATE:" + day[0])
    lines += head + body + ["END:VEVENT"]
    for o in moved:
        o_start = local(o.get("start"), tz)
        if not o_start or o.get("cancelled"):
            continue
        lines += ["BEGIN:VEVENT", "UID:" + str(ev["uid"]), "SUMMARY:" + esc(o.get("summary") or ev.get("summary") or "Untitled")]
        if rev:
            lines.append("X-ALMANAC-REV:" + rev)
        rid = local(o.get("recurrenceId"), tz)
        if rid:
            lines.append("RECURRENCE-ID;VALUE=DATE:" + rid[0])
        lines += dt_lines(o_start, local(o.get("end"), tz), all_day) + ["END:VEVENT"]
lines.append("END:VCALENDAR")
sys.stdout.write("\r\n".join(lines) + "\r\n")'
}

new_uid() {
  python3 -c 'import json, sys, uuid
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = {}
uid = str(d.get("uid") or "").strip() if isinstance(d, dict) else ""
sys.stdout.write(uid or "evt-" + uuid.uuid4().hex)' "$1"
}

body_uid() {
  python3 -c 'import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = {}
sys.stdout.write(str(d.get("uid") or "").strip() if isinstance(d, dict) else "")' "$1"
}

# The editor owns summary, start, end, allDay (only summary when the edit has
# no start: a title-only edit). Everything else comes from the current event,
# so a PUT (which needs the full body) loses nothing.
merge_event() {
  python3 -c 'import json, sys
current = json.load(open(sys.argv[1]))
edit = json.load(open(sys.argv[2]))
if not isinstance(current, dict) or not isinstance(edit, dict):
    sys.exit(1)
owned = ("summary", "start", "end", "allDay") if "start" in edit else ("summary",)
out = {k: v for k, v in current.items()
       if k not in ("uid", "seal", "rev", "sequence", "createdAt", "updatedAt", "sealed", "unreadable") + owned}
for k in owned:
    if k in edit:
        out[k] = edit[k]
json.dump(out, open(sys.argv[3], "w"))' "$1" "$2" "$3"
}

# skip_event CURRENT DATE TIME OUT: writes the event with that shown date in
# its exdates (and no override for it) to OUT, and prints the recurrence id.
skip_event() {
  python3 -c 'import json, sys
from datetime import datetime
try:
    from zoneinfo import ZoneInfo
except Exception:
    ZoneInfo = None

ev = json.load(open(sys.argv[1]))
day, hm, out = sys.argv[2], sys.argv[3], sys.argv[4]
if not ev.get("rrule"):
    sys.exit("not a repeating event")
zone = None
if ev.get("timeZone") and ZoneInfo:
    try:
        zone = ZoneInfo(ev["timeZone"])
    except Exception:
        zone = None
start = str(ev.get("start") or "")
all_day = bool(ev.get("allDay")) or len(start) == 10

# A timed value as an aware datetime: floating ones in the series zone, else local.
def parse(text):
    dt = datetime.fromisoformat(str(text).replace("Z", "+00:00"))
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=zone) if zone else dt.astimezone()
    return dt

# (YYYY-MM-DD, HH:MM) as the calendar shows it, in local time.
def shown(text):
    text = str(text or "")
    if len(text) == 10:
        return text, ""
    dt = parse(text).astimezone()
    return dt.strftime("%Y-%m-%d"), dt.strftime("%H:%M")

rid = ""
moved = [o for o in ev.get("overrides") or [] if isinstance(o, dict)]
for o in moved:
    try:
        d, t = shown(o.get("start"))
    except ValueError:
        continue
    if d == day and (all_day or not hm or t == hm):
        rid = str(o.get("recurrenceId") or "")
        break
if not rid and all_day:
    rid = day
if not rid:
    # The shown date and time, back in the series zone. The time of day is the
    # series start there, so the id is the one the server and the feed use.
    series = parse(start)
    if zone:
        series = series.astimezone(zone)
    when = datetime.fromisoformat(day + "T" + (hm or series.astimezone().strftime("%H:%M")))
    when = when.astimezone().astimezone(series.tzinfo)
    rid = when.strftime("%Y-%m-%d") + "T" + series.strftime("%H:%M:%S")
ev["exdates"] = sorted(set(str(x) for x in ev.get("exdates") or []) | {rid})
kept = [o for o in moved if str(o.get("recurrenceId") or "") != rid]
if kept:
    ev["overrides"] = kept
else:
    ev.pop("overrides", None)
json.dump(ev, open(out, "w"))
print(rid)' "$1" "$2" "$3" "$4"
}

case "$CMD" in
  list)
    request GET "$EVENTS"
    finish
    ;;
  ics)
    request GET "$EVENTS"
    [[ $CODE == 200 ]] || finish
    OPENED=$(almanac_tmp) || fail "Agent Cloud request failed"
    almanac_open event <"$OUT" >"$OPENED" || fail "sealed calendar needs the agentcloud or almanac binary"
    to_ics <"$OPENED" || fail "bad events"
    exit 0
    ;;
  delete)
    request DELETE "$EVENTS/$ITEM" "" "$REV"
    finish
    ;;
  skip)
    FEED=$(almanac_feed) || fail "Agent Cloud request failed"
    request GET "$EVENTS/$ITEM"
    [[ $CODE == 404 && -n $REV ]] && fail "conflict"
    [[ $CODE == 200 ]] || finish
    CURRENT=$(almanac_tmp) || fail "Agent Cloud request failed"
    almanac_open event <"$OUT" >"$CURRENT" || fail "sealed calendar needs the agentcloud or almanac binary"
    read -r UNREADABLE BASE_REV < <(python3 -c 'import json, sys
d = json.load(open(sys.argv[1]))
print("1" if d.get("unreadable") else "0", d.get("rev") or "")' "$CURRENT")
    [[ $UNREADABLE == 0 ]] || fail "could not open the seal"
    # The server checks If-Match on events/{uid} only, not on its exdates
    # route, so a stale --rev is caught here as well.
    [[ -z $REV || $REV == "$BASE_REV" ]] || fail "conflict"
    SKIPPED=$(almanac_tmp) || fail "Agent Cloud request failed"
    RID=$(skip_event "$CURRENT" "$DATE" "$TIME" "$SKIPPED" 2>&1) || fail "${RID:-bad event}"
    if [[ $FEED == seal ]]; then
      SEALED=$(almanac_tmp) || fail "Agent Cloud request failed"
      almanac_seal_body event "$ITEM" "$SKIPPED" "$SEALED" || fail "could not seal the event"
      request PUT "$EVENTS/$ITEM" "$SEALED" "$BASE_REV"
    else
      BODY=$(almanac_tmp) || fail "Agent Cloud request failed"
      python3 -c 'import json, sys; json.dump({"recurrenceId": sys.argv[1]}, open(sys.argv[2], "w"))' "$RID" "$BODY" || fail "bad event"
      request PUT "$EVENTS/$ITEM/exdates" "$BODY" "$BASE_REV"
    fi
    finish
    ;;
  post)
    FEED=$(almanac_feed) || fail "Agent Cloud request failed"
    ITEM=$(body_uid "$BODYFILE")
    if [[ -n $ITEM ]]; then
      # Update: read, merge, PUT with If-Match. Cloudflare blocks PATCH.
      request GET "$EVENTS/$ITEM"
      [[ $CODE == 404 && -n $REV ]] && fail "conflict"
      [[ $CODE == 200 || ( $CODE == 404 && -z $REV ) ]] || finish
      [[ $CODE == 404 ]] && ITEM=""   # a new event with a chosen uid
    fi
    if [[ -z $ITEM ]]; then
      if [[ $FEED == seal ]]; then
        UID_VALUE=$(new_uid "$BODYFILE") || fail "bad event"
        SEALED=$(almanac_tmp) || fail "Agent Cloud request failed"
        almanac_seal_body event "$UID_VALUE" "$BODYFILE" "$SEALED" || fail "could not seal the event"
        request PUT "$EVENTS/$UID_VALUE" "$SEALED"
      elif [[ -n $(body_uid "$BODYFILE") ]]; then
        request PUT "$EVENTS/$(body_uid "$BODYFILE")" "$BODYFILE"
      else
        request POST "$EVENTS" "$BODYFILE"
      fi
      finish
    fi
    CURRENT=$(almanac_tmp) || fail "Agent Cloud request failed"
    almanac_open event <"$OUT" >"$CURRENT" || fail "sealed calendar needs the agentcloud or almanac binary"
    read -r UNREADABLE BASE_REV < <(python3 -c 'import json, sys
d = json.load(open(sys.argv[1]))
print("1" if d.get("unreadable") else "0", d.get("rev") or "")' "$CURRENT")
    [[ $UNREADABLE == 0 ]] || fail "could not open the seal"
    REPEATS=$(python3 -c 'import json, sys
current = json.load(open(sys.argv[1]))
edit = json.load(open(sys.argv[2]))
print("1" if current.get("rrule") and any(k in edit for k in ("start", "end", "allDay")) else "0")' "$CURRENT" "$BODYFILE") || fail "bad event"
    [[ $REPEATS == 0 ]] || fail "repeating event: only the title can change here"
    MERGED=$(almanac_tmp) || fail "Agent Cloud request failed"
    merge_event "$CURRENT" "$BODYFILE" "$MERGED" || fail "bad event"
    if [[ $FEED == seal ]]; then
      SEALED=$(almanac_tmp) || fail "Agent Cloud request failed"
      almanac_seal_body event "$ITEM" "$MERGED" "$SEALED" || fail "could not seal the event"
      MERGED="$SEALED"
    fi
    # Without --rev, the rev just read guards the merge.
    request PUT "$EVENTS/$ITEM" "$MERGED" "${REV:-$BASE_REV}"
    finish
    ;;
esac
