# Dottie Calendar

Omarchy calendar app. Day, week, month, and year. Almanac events plus ICS feeds.

**New** (or `n`) adds an event on the selected day. Click an Almanac event to edit or delete. An edit is a PUT of the full event (Cloudflare blocks PATCH) with the event's rev as `If-Match`; fields the editor does not show (place, notes, repeat rule, time zone) are kept. A repeating event can change its title here, not its date or times (that would move the whole series). If the event changed or was deleted elsewhere, the server's version stays and your edit is saved as a new event titled `… (conflict copy)`. A sealed calendar is written as a seal and opened locally.

The Almanac calendar syncs from its JSON API through `scripts/almanac-events.sh` (built on `scripts/almanac-lib.sh`, a copy of `clients/shell/almanac-lib.sh` from the almanac repo), not from its ICS feed. Requests carry the auth token on curl's stdin, never the key. Other feeds are plain ICS. The window syncs when it opens and every minute while open. The local store (`~/.local/state/omarchy/sd-calendar.json`) is written `0600`.

Launch as **dottie** or **calendar**. Plugin id is `sd.calendar`.

## Install

Review the plugin, then enable it. Omarchy plugins run unsandboxed inside `omarchy-shell`.

```sh
omarchy plugin add https://github.com/stevederico/dottie-calendar-omarchy.git
omarchy plugin enable sd.calendar --section right
```

Build the backend if `bin/sd-calendar` is missing:

```sh
cargo build --release --manifest-path backend/Cargo.toml
```

The backend finds `scripts/almanac-events.sh` next to `bin/`. Set `SD_CALENDAR_ALMANAC_SCRIPT` for a build elsewhere.

## Tests

```sh
node --test tests/*.js
cargo test --manifest-path backend/Cargo.toml
ALMANAC_BIN=~/Projects/almanac/target/debug/almanac bash tests/almanac_server.sh
```

`tests/almanac_server.sh` runs the script and `bin/sd-calendar sync` against a throwaway Almanac server (plain and sealed calendars, stale `--rev`, no key or token in `ps`).
