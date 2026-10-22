#!/bin/bash
# Luxeia dashboard updater. The Luxeia add-on (addon/run.sh) runs it on
# start, nightly and when someone taps "Check for updates"; see RELEASING.md.
#
# It asks Luxeia's update server (server/) for the build the owner approved
# for this home, and installs it only if:
#   - the server's approval is signed with a key in approval-keys/;
#   - the build is signed with a key in keys/ (verify-build.sh);
#   - both are about the same download;
#   - the approval (seq) is no older than the last this home had.
# It reports back (check-in) after every run.
#
# The home key is in $LUXEIA_DIR/update.conf (HOME_KEY=lxh_..., and
# optionally SERVER=...), never on the command line: arguments show in
# logs and the process list. Arguments are ignored (older callers passed a
# channel; the server decides now).
#
# The add-on sets LUXEIA_DIR, WWW_DIR and VERSION_FILE to its own folders,
# and LUXEIA_ADDON_VERSION (reported in the check-in). The server's channel
# for this home ("beta" for test homes) is kept in $LUXEIA_DIR/channel, so
# the add-on can check test homes more often.
#
# HA OS uses BusyBox: plain options only.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LUXEIA_DIR="${LUXEIA_DIR:?LUXEIA_DIR required (the add-on sets it)}"
WWW_DIR="${WWW_DIR:?WWW_DIR required (the add-on sets it)}"
VERSION_FILE="${VERSION_FILE:?VERSION_FILE required (the add-on sets it)}"
KEYS_DIR="${KEYS_DIR:-$HERE/keys}"
APPROVAL_KEYS_DIR="${APPROVAL_KEYS_DIR:-$HERE/approval-keys}"
CONF="${LUXEIA_DIR}/update.conf"
PREVIOUS="${LUXEIA_DIR}/previous"
SEQ_FILE="${LUXEIA_DIR}/approval-seq"
ASSET="dashboard.tar.gz"

conf_value() { # NAME: its value from update.conf (read, never run)
  [ -f "$CONF" ] || return 0
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CONF" | tail -n1 | tr -d '\r"'"'"
}
HOME_KEY="$(conf_value HOME_KEY)"
SERVER="${LUXEIA_SERVER:-$(conf_value SERVER)}"
SERVER="${SERVER:-https://updates.luxeia.co.uk}"
[ -n "$HOME_KEY" ] || { echo "No home key: put HOME_KEY=... in ${CONF}" >&2; exit 1; }

mkdir -p "$LUXEIA_DIR"
WORK="$(mktemp -d "${LUXEIA_DIR}/update.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Every step checks itself: callers may run it where `set -e` doesn't apply
install_build() { # tarball (already checked)
  # Unpack beside the live build, so it's untouched until the very last step
  mkdir "$WORK/new" && tar -xzf "$1" -C "$WORK/new" || { echo "Couldn't unpack the build" >&2; exit 1; }
  for f in index.html build.json js/app.js styles/tokens.css; do
    [ -s "$WORK/new/$f" ] || { echo "Downloaded build is missing $f" >&2; exit 1; }
  done

  # Swap: two renames on the same disk. The old build is kept beside it
  # for a manual rollback (RELEASING.md › One home only).
  rm -rf "$PREVIOUS" || { echo "Couldn't clear the previous build" >&2; exit 1; }
  if [ -d "$WWW_DIR" ]; then
    mv "$WWW_DIR" "$PREVIOUS" || { echo "Couldn't move the live build aside; it's unchanged" >&2; exit 1; }
  fi
  mkdir -p "$(dirname "$WWW_DIR")"
  if ! mv "$WORK/new" "$WWW_DIR"; then
    [ -d "$PREVIOUS" ] && mv "$PREVIOUS" "$WWW_DIR"
    echo "Couldn't put the new build in place; the old one is back" >&2
    exit 1
  fi
}

# The home key goes to curl through its standard input, never as an argument
server() { # path [curl options...]
  local path="$1"
  shift
  printf 'header = "Authorization: Bearer %s"\n' "$HOME_KEY" | curl -K - -fsSL "$@" "${SERVER}${path}"
}
# Tells the server how this home is doing; it emails the owner about
# homes that go quiet or report a problem
checkin() { # problem (empty when all is well)
  local version=""
  [ -f "$WWW_DIR/build.json" ] && version="$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$WWW_DIR/build.json" | head -n1)"
  python3 -I -c 'import json, sys; print(json.dumps({"version": sys.argv[1], "error": sys.argv[2][:300], "addon": sys.argv[3]}))' "$version" "$1" "${LUXEIA_ADDON_VERSION:-}" > "$WORK/checkin.json"
  server /v1/checkin -X POST -H 'Content-Type: application/json' --data-binary "@$WORK/checkin.json" -o /dev/null 2>/dev/null || true
}
fail() { echo "$*" >&2; checkin "$*"; exit 1; }
done_ok() { checkin ""; exit 0; }

ls "$KEYS_DIR"/*.pem >/dev/null 2>&1 || fail "Refused: this home has no build keys (copy updater/keys/ to $KEYS_DIR)"
ls "$APPROVAL_KEYS_DIR"/*.pem >/dev/null 2>&1 || fail "Refused: this home has no approval keys (copy updater/approval-keys/ to $APPROVAL_KEYS_DIR)"

server /v1/update -o "$WORK/update.json" 2>"$WORK/curl.err" \
  || fail "Couldn't reach the update server, or it didn't recognise this home's key: $(tr '\n' ' ' < "$WORK/curl.err")"

# The answer, written out byte for byte so the signatures can be checked
offer="$(python3 -I -c '
import json, re, sys
d = json.load(open(sys.argv[1]))
channel = d.get("channel")
if isinstance(channel, str) and re.fullmatch(r"[a-z]{1,20}", channel):
  open(sys.argv[3], "w").write(channel + "\n")
if d.get("paused"):
  print("paused")
elif d.get("none"):
  print("none")
else:
  for name, text in (("approval.json", d["approval"]["manifest"]), ("approval.sig", d["approval"]["sig"]),
                     ("build-manifest.json", d["build"]["manifest"]), ("build-manifest.sig", d["build"]["sig"])):
      open(sys.argv[2] + "/" + name, "wb").write(text.encode("utf-8"))
  print("offer " + d["download"])
' "$WORK/update.json" "$WORK" "$LUXEIA_DIR/channel")" || fail "The update server's answer wasn't readable"
case "$offer" in
  paused) echo "Updates are paused; keeping this build"; done_ok ;;
  none) echo "Nothing approved for this home yet"; done_ok ;;
esac
download="${offer#offer }"

# 1. The owner approved it: signed with an approval key
out="$(bash "$HERE/verify-build.sh" --signature "$WORK/approval.json" "$WORK/approval.sig" "$APPROVAL_KEYS_DIR" 2>&1)" \
  || fail "Refused: the approval isn't signed with Luxeia's approval key (${out#Refused: })"

# 2. The approval and the build are about the same download, and the
# approval is no older than the last this home had (no playing back
# old ones). Only read once its signature has checked out.
facts="$(python3 -I -c '
import json, re, sys
a = json.load(open(sys.argv[1]))
b = json.load(open(sys.argv[2]))
ok = (a.get("build") == b.get("build") and a.get("sha256") == b.get("sha256")
    and re.fullmatch(r"[0-9a-f]{64}", a.get("sha256") or "") and type(a.get("seq")) is int and a["seq"] > 0
    and re.fullmatch(r"build-[A-Za-z0-9._-]+", a.get("build") or ""))
print("%d %s %s" % (a["seq"], a["sha256"], a["build"]) if ok else "mismatch")
' "$WORK/approval.json" "$WORK/build-manifest.json")" || fail "Refused: the approval isn't readable"
[ "$facts" != mismatch ] || fail "Refused: the approval and the build don't match"
seq="${facts%% *}"
rest="${facts#* }"
sha="${rest%% *}"
build="${rest#* }"
[ "$download" = "/v1/build/${build}" ] || fail "Refused: the download isn't the approved build"
last_seq=0
[ -f "$SEQ_FILE" ] && last_seq="$(tr -cd '0-9' < "$SEQ_FILE")"
last_seq="${last_seq:-0}"
[ "$seq" -ge "$last_seq" ] || fail "Refused: an older approval (${seq}) than this home has already had (${last_seq})"

current_digest=""
[ -f "$VERSION_FILE" ] && current_digest="$(cat "$VERSION_FILE")"
if [ "sha256:${sha}" = "$current_digest" ]; then
  echo "$seq" > "$SEQ_FILE"
  done_ok
fi
[ "$seq" -gt "$last_seq" ] || fail "Refused: the same approval (${seq}) for a different build"

free_kb="$(df -Pk "$LUXEIA_DIR" | awk 'NR == 2 { print $4 }')"
if [ -n "$free_kb" ] && [ "$free_kb" -lt 40960 ]; then
  fail "Not enough free space to update (${free_kb} KB free)"
fi

server "$download" -o "$WORK/$ASSET" 2>"$WORK/curl.err" \
  || fail "Couldn't download the build: $(tr '\n' ' ' < "$WORK/curl.err")"

# 3. Luxeia built it, it's that download, and it's safe to unpack
out="$(bash "$HERE/verify-build.sh" "$WORK/$ASSET" "$WORK/build-manifest.json" "$WORK/build-manifest.sig" "$KEYS_DIR" 2>&1)" \
  || fail "$out"

out="$(install_build "$WORK/$ASSET" 2>&1)" || fail "$out"
echo "sha256:${sha}" > "$VERSION_FILE"
echo "$seq" > "$SEQ_FILE"
echo "Installed ${build}"
done_ok
