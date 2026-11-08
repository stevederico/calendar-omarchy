# Agent Cloud Calendar

Omarchy calendar app. Day, week, month, and year. Agent Cloud events plus ICS feeds.

**New** (or `n`) adds an event on the selected day. Click an Agent Cloud event to edit or delete. An edit is a PUT of the full event (Cloudflare blocks PATCH) with the event's rev as `If-Match`; fields the editor does not show (place, notes, repeat rule, time zone) are kept. A repeating event can change its title here, not its date or times (that would move the whole series). Delete on a repeating event asks **This date** (an exdate for that one date, inside the seal on a sealed calendar) or **All dates** (the series). If the event changed or was deleted elsewhere, the server's version stays and your edit is saved as a new event titled `… (conflict copy)`. A sealed calendar is written as a seal and opened locally.

The Agent Cloud calendar syncs from its JSON API (`https://cloud.bixbyapps.com`) through `scripts/cloud-events.sh` (built on `scripts/cloud-lib.sh`, a copy of `clients/shell/cloud-lib.sh` from the Agent Cloud server repo, `stevederico/agentcloud`), not from its ICS feed. The key lives in `~/.config/agentcloud/hosted-calendars.json`. Requests carry the auth token on curl's stdin, never the key. Other feeds are plain ICS. The window syncs when it opens and every minute while open. The local store (`~/.local/state/omarchy/sd-calendar.json`) is written `0600`.

Launch as **agentcloud** or **calendar**. Plugin id is `sd.calendar`.

## Install

Review the plugin, then enable it. Omarchy plugins run unsandboxed inside `omarchy-shell`.

```sh
omarchy plugin add https://github.com/stevederico/calendar-omarchy.git
omarchy plugin enable sd.calendar --section right
```

Build the backend if `bin/sd-calendar` is missing:

```sh
cargo build --release --manifest-path backend/Cargo.toml
```

The backend finds `scripts/cloud-events.sh` next to `bin/`. Set `SD_CALENDAR_CLOUD_SCRIPT` for a build elsewhere (`SD_CALENDAR_ALMANAC_SCRIPT` still works).

## Moving from Dottie Calendar

This app was Dottie Calendar (`dottie-calendar-omarchy`). Nothing to move by hand:

- Credentials: read from `~/.config/agentcloud/hosted-calendars.json`. While that file is missing, the old `~/.config/almanac/hosted-calendars.json` is read instead. Move it when you like: `mkdir -p ~/.config/agentcloud && mv ~/.config/almanac/hosted-calendars.json ~/.config/agentcloud/`.
- Server: `https://cloud.bixbyapps.com`. A credentials file whose write URL is on `almanac.dottie.ai` talks to the new host, and a feed subscribed on the old host still syncs through the JSON API.
- Local store, plugin id and backend are unchanged: `~/.local/state/omarchy/sd-calendar.json`, `sd.calendar`, `bin/sd-calendar`. A calendar still named `Almanac` shows as Agent Cloud.
- IPC: the `dottie`, `dot` and `almanac` targets are gone. Use `sd.calendar`, `calendar` or `agentcloud-calendar`.
- Sealed calendars need the `agentcloud` (or older `almanac`) binary for seal and open.
- Code names: `Almanac.js`, `AlmanacRemote.qml`, `scripts/almanac-events.sh` and the tests are now `Cloud.js`, `CloudRemote.qml`, `scripts/cloud-events.sh`, `tests/cloud_server.sh` and `tests/test_cloud.js`. The script hands the backend `X-CLOUD-REV`; the backend still reads `X-ALMANAC-REV`.
- Git remote: `git remote set-url origin https://github.com/stevederico/calendar-omarchy.git` in an existing clone.

## Tests

```sh
node --test tests/*.js
cargo test --manifest-path backend/Cargo.toml
AGENTCLOUD_BIN=~/Projects/agentcloud/target/debug/agentcloud bash tests/cloud_server.sh   # or ALMANAC_BIN for an older almanac build
```

`tests/cloud_server.sh` runs the script and `bin/sd-calendar sync` against a throwaway Agent Cloud server built from the agentcloud repo (plain and sealed calendars, stale `--rev`, one date of a weekly series skipped, no key or token in `ps`).
