#!/bin/bash
# Checks a dashboard download before anything is installed. Runs on homes
# (HA OS: BusyBox, so plain options only) and in scripts/sign-build.sh.
#
# Usage:
#   verify-build.sh <tarball> <manifest> <signature> <keys dir>
#   verify-build.sh --unsigned <tarball>     (only the archive checks)
#   verify-build.sh --signature <file> <signature> <keys dir>
#       only that <file> was signed by one of the keys (the update
#       server's approval, checked against updater/approval-keys/)
#
# Passes (exit 0) only if:
#   - the signature over the manifest was made by one of the public keys in
#     <keys dir> (*.pem, Ed25519), so the build came from Luxeia's release;
#   - the tarball's sha256 is the one in the manifest, so it's that build;
#   - every path in the archive stays inside the folder it's unpacked into
#     (nothing absolute, no "..", no links);
#   - the files every build has are there.
# --unsigned skips the first two. See secure_updates_plan.md.
#
# Signatures are checked with openssl (3.0 or later) where it can, or else
# Python's cryptography library, which Home Assistant itself depends on.
# VERIFY_WITH=openssl|python picks one (for tests).
set -euo pipefail

die() { echo "Refused: $*" >&2; exit 1; }

UNSIGNED=0
SIGNATURE_ONLY=0
if [ "${1:-}" = "--signature" ]; then
  SIGNATURE_ONLY=1
  MANIFEST="${2:?file required}"
  SIGNATURE="${3:?signature required}"
  KEYS_DIR="${4:?keys dir required}"
elif [ "${1:-}" = "--unsigned" ]; then
  UNSIGNED=1
  shift
  TARBALL="${1:?tarball required}"
else
  TARBALL="${1:?tarball required}"
  MANIFEST="${2:?manifest required}"
  SIGNATURE="${3:?signature required}"
  KEYS_DIR="${4:?keys dir required}"
fi
[ "$SIGNATURE_ONLY" = 1 ] || [ -s "$TARBALL" ] || die "the download is missing or empty"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

have_openssl() { command -v openssl >/dev/null 2>&1 && openssl pkeyutl -help 2>&1 | grep -q rawin; }
have_python() { command -v python3 >/dev/null 2>&1 && python3 -I -c 'import cryptography.hazmat.primitives.asymmetric.ed25519' 2>/dev/null; }

verify_with_openssl() { # key manifest signature.bin
  openssl pkeyutl -verify -pubin -inkey "$1" -rawin -in "$2" -sigfile "$3" >/dev/null 2>&1
}
verify_with_python() { # key manifest signature.bin
  python3 -I -c '
import sys
from cryptography.hazmat.primitives.serialization import load_pem_public_key
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
key = load_pem_public_key(open(sys.argv[1], "rb").read())
if not isinstance(key, Ed25519PublicKey):
    sys.exit(1)
key.verify(open(sys.argv[3], "rb").read(), open(sys.argv[2], "rb").read())
' "$1" "$2" "$3" >/dev/null 2>&1
}

if [ "$UNSIGNED" = 0 ]; then
  [ -s "$MANIFEST" ] || die "the build's manifest is missing"
  [ -s "$SIGNATURE" ] || die "the build isn't signed"

  case "${VERIFY_WITH:-}" in
    openssl) check=verify_with_openssl ;;
    python) check=verify_with_python ;;
    "")
      if have_openssl; then check=verify_with_openssl
      elif have_python; then check=verify_with_python
      else die "this home has no way to check signatures (needs openssl 3 or Python's cryptography)"
      fi ;;
    *) die "VERIFY_WITH must be openssl or python" ;;
  esac

  # The signature is kept as base64 text; BusyBox and GNU both take -d
  base64 -d < "$SIGNATURE" > "$WORK/sig.bin" 2>/dev/null || die "the signature isn't readable"

  trusted=""
  for key in "$KEYS_DIR"/*.pem; do
    [ -f "$key" ] || continue
    if "$check" "$key" "$MANIFEST" "$WORK/sig.bin"; then
      trusted="$key"
      break
    fi
  done
  [ -n "$trusted" ] || die "the signature doesn't match any of Luxeia's keys"
  if [ "$SIGNATURE_ONLY" = 1 ]; then
    echo "Verified (signed by $(basename "$trusted" .pem))"
    exit 0
  fi

  # Only now is the manifest trusted enough to read
  want="$(sed -n 's/.*"sha256":"\([0-9a-f]\{64\}\)".*/\1/p' "$MANIFEST")"
  [ -n "$want" ] || die "the manifest has no checksum"
  got="$(sha256sum "$TARBALL" | cut -d' ' -f1)"
  [ "$got" = "$want" ] || die "the download isn't the build that was signed"
fi

# Every path must stay inside the folder, and nothing may be a link
tar -tzf "$TARBALL" > "$WORK/list" 2> "$WORK/warnings" || die "the download isn't a readable archive"
# GNU and BusyBox tar both strip a leading "/" or "../" with a warning (and
# BusyBox's listing then hides it), so any warning at all is refused
[ -s "$WORK/warnings" ] && die "the archive tries to write outside its folder"
if grep -E '^/|(^|/)\.\.(/|$)' "$WORK/list" >/dev/null; then
  die "the archive tries to write outside its folder"
fi
tar -tvzf "$TARBALL" > "$WORK/long" 2>/dev/null || die "the download isn't a readable archive"
if cut -c1 "$WORK/long" | grep -E '^[lhbcp]' >/dev/null || grep -E ' -> | link to ' "$WORK/long" >/dev/null; then
  die "the archive contains links or special files"
fi

for f in index.html build.json js/app.js styles/tokens.css; do
  grep -E "^(\./)?${f}\$" "$WORK/list" >/dev/null || die "the build is missing ${f}"
done

echo "Verified${trusted:+ (signed by $(basename "$trusted" .pem))}"
