#!/bin/bash
# The Luxeia add-on (secure_updates_plan.md, stage 4). Serves the dashboard
# only to people signed in to this home (HA's ingress), and keeps it up to
# date from Luxeia's update server with the same updater homes use today
# (check-update.sh, both signatures, seq). See DOCS.md.
#
#   - on start, then once a night at a random time between 2am and 5am
#     (every 15 minutes on test homes, so a build approved for them arrives
#     within minutes), and
#     whenever "check" arrives on stdin ("Check for updates" in the app,
#     through hassio.addon_stdin), it runs the updater;
#   - serve.py serves the build to HA's ingress proxy only, telling phones
#     to keep each file until the next build;
#   - update-status.json beside the build says how the last check went
#     ({running, finished, result, message}), for the app;
#   - with "Keep only the guest page public" on, /config/www/luxeia-dashboard
#     (HA's public /local/ folder) holds just the guest page's files
#     (guest-files.txt in each build), so guest links keep working, and the
#     opener as its index.html (opener.html), so the home's Webpage
#     dashboard, the app's default screen, still opens Luxeia Home by itself.
#
# The home key comes from the add-on's options: never on a command line,
# never in HA's log. That box takes the key itself (lxh_...) or, for a new
# home, the short set-up code from the admin page, which is swapped for the
# key once (the server's /v1/enrol) and kept in $STATE/home-key.
#
# For tests, LUXEIA_ONCE=1 runs one check and stops (no web server or
# timer), LUXEIA_ONCE=stdin handles stdin's lines and stops at its end, and
# LUXEIA_ONCE=next prints the seconds until the next check.
# LUXEIA_APP_DIR, LUXEIA_DATA_DIR, HA_CONFIG_DIR, LUXEIA_SERVER_CMD,
# LUXEIA_PORT and LUXEIA_ALLOW_IP replace the add-on's own paths and
# settings.
set -uo pipefail

APP="${LUXEIA_APP_DIR:-/opt/luxeia}"
DATA="${LUXEIA_DATA_DIR:-/data}"
HA_CONFIG="${HA_CONFIG_DIR:-/homeassistant}"
SERVER_CMD="${LUXEIA_SERVER_CMD:-python3 -I}"
PORT="${LUXEIA_PORT:-8099}"
# Requests come only from HA's ingress proxy (the Supervisor's address)
ALLOW_IP="${LUXEIA_ALLOW_IP:-172.30.32.2}"

STATE="$DATA/luxeia"          # update.conf, seq, version, previous build
ASKED="$STATE/check-asked"    # left by serve.py when the app asks for a check
WWW="$DATA/www"
LIVE="$WWW/luxeia-dashboard"  # what's served
WAITING="$WWW/waiting"        # served until the first build arrives
PUBLIC="$HA_CONFIG/www/luxeia-dashboard"

log() { echo "[luxeia] $*"; }

# This add-on's id: local_luxeia when copied in by hand, <code>_luxeia from
# the add-on store. Home Assistant names its container after it, with "-"
# for "_".
SLUG="${LUXEIA_SLUG:-$(hostname 2>/dev/null | tr '-' '_')}"
case "$SLUG" in
  *[!a-z0-9_]*|"") SLUG=local_luxeia ;;
esac
# This add-on's version (its config.yaml is copied in), for the check-in
ADDON_VERSION="$(sed -n 's/^version: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' "$APP/config.yaml" 2>/dev/null | head -n1)"
# How often test homes check (seconds)
TEST_EVERY="${LUXEIA_TEST_EVERY:-900}"

option() { # name: its value from options.json ("" when unset)
  python3 -I -c '
import json, sys
try:
    v = json.load(open(sys.argv[1])).get(sys.argv[2])
except Exception:
    v = None
print("" if v is None else (str(v).lower() if isinstance(v, bool) else v))
' "$DATA/options.json" "$1"
}

mkdir -p "$STATE" "$WWW"
chmod 700 "$STATE"
KEY_OPTION="$(option home_key | tr -d '[:space:]')"
SERVER="$(option server)"
GUEST_ONLY="$(option public_guest_page_only)"
HOME_KEY=""
KEY_FROM=""     # key | code | none, for the app's set-up check
KEY_PROBLEM=""  # why a set-up code didn't work

# The updater reads its key from update.conf, never its command line
write_conf() {
  (umask 077; {
    echo "HOME_KEY=${HOME_KEY}"
    [ -n "$SERVER" ] && echo "SERVER=${SERVER}"
  } > "$STATE/update.conf")
}

# The home key, from the add-on's options: the key itself, or a set-up code
# swapped for it once. A code already swapped is remembered (by its hash),
# so restarting doesn't spend it again; a different code is swapped anew.
find_key() {
  KEY_PROBLEM=""
  case "$KEY_OPTION" in
    "") HOME_KEY=""; KEY_FROM=none; write_conf; return 0 ;;
    lxh_*) HOME_KEY="$KEY_OPTION"; KEY_FROM=key; write_conf; return 0 ;;
  esac
  KEY_FROM=code
  local code hash answer
  code="$(printf '%s' "$KEY_OPTION" | tr 'a-z' 'A-Z' | tr -cd 'A-Z0-9')"
  hash="$(printf '%s' "$code" | sha256sum | cut -d' ' -f1)"
  if [ -s "$STATE/home-key" ] && [ "$(cat "$STATE/home-key-code" 2>/dev/null)" = "$hash" ]; then
    HOME_KEY="$(cat "$STATE/home-key")"
    write_conf
    return 0
  fi
  HOME_KEY=""
  write_conf
  log "Using the set-up code to get this home's key"
  # The code goes to curl on its standard input, never as an argument
  rm -f "$STATE/enrol.json"
  if ! printf '{"code": "%s"}' "$code" | curl -sS -m 30 -X POST -H 'Content-Type: application/json' \
      --data-binary @- -o "$STATE/enrol.json" "${SERVER:-https://updates.luxeia.co.uk}/v1/enrol" 2>/dev/null; then
    KEY_PROBLEM="Couldn't reach Luxeia's update server to use the set-up code. It'll try again at the next check."
    log "$KEY_PROBLEM"
    return 1
  fi
  answer="$(python3 -I -c '
import json, re, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = {}
key = d.get("key") or ""
if re.fullmatch(r"lxh_[A-Za-z0-9_-]{20,200}", key):
    print("key " + key)
else:
    print("error " + str(d.get("error") or "the update server did not give a key")[:200])
' "$STATE/enrol.json")"
  rm -f "$STATE/enrol.json"
  case "$answer" in
    "key "*)
      (umask 077; printf '%s\n' "${answer#key }" > "$STATE/home-key"; printf '%s\n' "$hash" > "$STATE/home-key-code")
      HOME_KEY="${answer#key }"
      write_conf
      log "This home is set up with Luxeia's update server (the set-up code is used up now)"
      return 0 ;;
    *)
      KEY_PROBLEM="The set-up code didn't work: ${answer#error }"
      log "$KEY_PROBLEM"
      return 1 ;;
  esac
}

# --- What the app reads -------------------------------------------------------

# update-status.json: how the last check went, and how this home is set up
# (for the app's Settings › Home system › Luxeia set-up)
status() { # running(true|false) result message
  local dir="$LIVE"
  # Never makes the build folder itself: one swapped in at that moment would
  # land inside an empty one it had just made
  [ -d "$dir" ] || { dir="$WAITING"; mkdir -p "$dir"; }
  python3 -I -c '
import datetime, json, os, sys
d, running, result, message, addon, slug, key, guest, channel = sys.argv[1:]
out = {"running": running == "true", "finished": datetime.datetime.now(datetime.timezone.utc).isoformat(), "result": result, "message": message[:300],
       "addon": addon, "slug": slug, "key": key, "guestOnly": guest == "true", "channel": channel}
tmp = os.path.join(d, ".update-status.json")
try:
    json.dump(out, open(tmp, "w"))
    os.replace(tmp, os.path.join(d, "update-status.json"))
except OSError:
    pass  # the build folder was being swapped: the next status lands in the new one
' "$dir" "$1" "$2" "${3:-}" "$ADDON_VERSION" "$SLUG" "${KEY_FROM:-none}" "$GUEST_ONLY" "$(cat "$STATE/channel" 2>/dev/null)"
}

waiting_page() { # message
  mkdir -p "$WAITING"
  python3 -I -c '
import html, sys
open(sys.argv[1], "w").write("""<!doctype html><html lang="en-GB"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><meta http-equiv="refresh" content="20">
<title>Luxeia Home</title><style>body{margin:0;min-height:100vh;display:grid;place-items:center;background:#161616;color:#F2EFE9;
font:17px/1.5 Montserrat,Roboto,system-ui,sans-serif;text-align:center;padding:24px;box-sizing:border-box}
@media (prefers-color-scheme: light){body{background:#F5F1EA;color:#222222}} svg{width:56px;height:56px;margin-bottom:16px}</style></head>
<body><main><svg viewBox="37 42 1032 1032" aria-hidden="true"><polygon points="553,42 1069,558 553,1074 37,558" fill="#BA9947"/>
<path d="M454 383H540V649H659V730H454Z" fill="#FFFFFF"/></svg><p>%s</p></main></body></html>""" % html.escape(sys.argv[2]))
' "$WAITING/index.html" "$1"
}

# --- The web server -----------------------------------------------------------

# serve.py (Python's standard library): it tells phones to keep each file
# of a build until the next one, which BusyBox's httpd couldn't, and looks
# up the build folder on every request, so a swapped-in build needs no
# restart
start_server() {
  # shellcheck disable=SC2086
  $SERVER_CMD "$APP/serve.py" "$PORT" "$ALLOW_IP" "$LIVE" "$WAITING" "$ASKED" &
}

# --- Keeping only the guest page public -----------------------------------------

sync_guest_page() {
  [ "$GUEST_ONLY" = true ] || return 0
  local list="$LIVE/guest-files.txt" new="$HA_CONFIG/www/.luxeia-guest.new" old="$HA_CONFIG/www/.luxeia-guest.old" f
  if [ ! -f "$list" ]; then
    log "This build doesn't list the guest page's files, so www/luxeia-dashboard is left as it is."
    return 0
  fi
  if [ -f "$HA_CONFIG/scripts/check-update.sh" ]; then
    log "Note: the old nightly update (/config/scripts/check-update.sh) is still there. It puts the whole dashboard back in www/luxeia-dashboard each night: remove it (DOCS.md)."
  fi
  rm -rf "$new" "$old"
  mkdir -p "$new"
  while IFS= read -r f; do
    case "$f" in ''|/*|*..*) continue ;; esac
    [ -f "$LIVE/$f" ] || continue
    mkdir -p "$new/$(dirname "$f")" && cp "$LIVE/$f" "$new/$f" || { log "Couldn't copy the guest page's files"; rm -rf "$new"; return 1; }
  done < "$list"
  if [ ! -s "$new/guest.html" ]; then
    log "The guest page is missing from this build, so www/luxeia-dashboard is left as it is."
    rm -rf "$new"
    return 1
  fi
  # Where the app's default screen points: the opener takes people on to the
  # add-on, which it finds by this add-on's own id first (it depends on where
  # the add-on was installed from, and people who can't change settings can
  # only ask about an add-on whose id they know). Phones keep index.html, so
  # it only fetches opener.js, fresh each time, which holds the id.
  cp "$APP/opener.html" "$new/index.html" \
    && sed "s/var ADDON = 'local_luxeia';/var ADDON = '${SLUG}';/" "$APP/opener.js" > "$new/opener.js" \
    && grep -q "var ADDON = '${SLUG}';" "$new/opener.js" \
    || { log "Couldn't copy the opener"; rm -rf "$new"; return 1; }
  # Swapped in one step, so guest links never see a half-copied folder
  [ -d "$PUBLIC" ] && mv "$PUBLIC" "$old"
  mv "$new" "$PUBLIC" && rm -rf "$old"
  # The old updater's public copy of the previous build
  rm -rf "$HA_CONFIG/www/luxeia-dashboard.previous"
  log "Only the guest page and the opener are public now (www/luxeia-dashboard)."
}

# --- Checking for a new build ----------------------------------------------------

check() {
  (
    flock -n 9 || { log "Already checking"; exit 0; }
    # The key (a set-up code is swapped for it the first time; one that
    # couldn't be used yet, with no internet, is tried again at each check)
    find_key
    if [ -n "$KEY_PROBLEM" ]; then
      [ -f "$LIVE/index.html" ] || waiting_page "Luxeia Home is almost ready. ${KEY_PROBLEM}"
      status false failed "$KEY_PROBLEM"
      exit 1
    fi
    if [ -z "$HOME_KEY" ]; then
      log "No home key yet: add its key or set-up code in the add-on's Configuration"
      [ -f "$LIVE/index.html" ] || waiting_page "Luxeia Home is almost ready. Add this home's key or set-up code in the add-on's Configuration, then restart it."
      status false failed "No home key yet"
      exit 1
    fi
    status true running ""
    local out code
    out="$(LUXEIA_DIR="$STATE" WWW_DIR="$LIVE" VERSION_FILE="$STATE/version" LUXEIA_ADDON_VERSION="$ADDON_VERSION" \
      KEYS_DIR="$APP/keys" APPROVAL_KEYS_DIR="$APP/approval-keys" \
      bash "$APP/check-update.sh" 2>&1)"
    code=$?
    [ -n "$out" ] && log "$out"
    if [ "$code" != 0 ]; then
      [ -f "$LIVE/index.html" ] || waiting_page "Luxeia Home couldn't fetch the dashboard yet. It'll try again tonight, or restart the add-on to try now."
      status false failed "$(printf '%s' "$out" | tail -n1)"
      exit 1
    fi
    case "$out" in
      *Installed*)
        status false installed "$(printf '%s' "$out" | tail -n1)"
        sync_guest_page ;;
      *paused*) status false paused "" ;;
      *) status false latest "" ;;
    esac
  ) 9>"$STATE/lock"
}

# Seconds until a random time between 2am and 5am (local time), so homes
# don't all ask the server at once
until_tonight() {
  python3 -I -c '
import datetime, random
now = datetime.datetime.now()
at = now.replace(hour=2, minute=0, second=0, microsecond=0) + datetime.timedelta(minutes=random.randint(0, 179))
if at <= now:
    at += datetime.timedelta(days=1)
print(int((at - now).total_seconds()))
'
}

# Until the next check: test homes (the server's "beta" channel, which
# check-update.sh keeps in $STATE/channel) every 15 minutes, others tonight
until_next() {
  if [ "$(cat "$STATE/channel" 2>/dev/null)" = beta ]; then echo "$TEST_EVERY"; else until_tonight; fi
}

# --- Running ---------------------------------------------------------------------

# "Check for updates" in the app (serve.py leaves the asked file)
watch_asked() {
  while true; do
    if [ -f "$ASKED" ]; then
      rm -f "$ASKED"
      log "Asked to check for updates (from the app)"
      check
    fi
    sleep "${LUXEIA_ASK_POLL:-3}"
  done
}

listen() { # handles "check" lines (hassio.addon_stdin sends them as JSON strings)
  local line
  while IFS= read -r line; do
    line="${line//\"/}"
    case "${line//[[:space:]]/}" in
      check|update) log "Asked to check for updates"; check ;;
      "") ;;
      *) log "Ignored: ${line:0:40}" ;;
    esac
  done
}

[ -f "$LIVE/index.html" ] || waiting_page "Setting up Luxeia Home. This page will refresh by itself."

case "${LUXEIA_ONCE:-}" in
  1) check; code=$?; sync_guest_page; exit "$code" ;;
  stdin) listen; exit 0 ;;
  next) until_next; exit 0 ;;
esac

trap 'kill $(jobs -p) 2>/dev/null; exit 0' TERM INT
log "Running as ${SLUG}, version ${ADDON_VERSION:-unknown}"
start_server
sync_guest_page
check
( while true; do sleep "$(until_next)"; check; done ) &
watch_asked &
listen
# stdin closed: keep serving until the add-on is stopped
wait
