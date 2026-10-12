#!/bin/sh
# grok-release.sh — single source of truth for grok-smartpi release endpoints.
# Sourced by install.sh and bin/grok-check-update. Never duplicate this logic.
#
# Releases are prereleases tagged `snapshot-armv7-<short upstream sha>` on
# Yumi-Lab/grok-smartpi, each carrying two assets:
#   grok-armv7          the armv7l binary (ELF 32-bit, glibc)
#   grok-armv7.sha256   its sha256 ("<hash>  grok-armv7")
#
# `gh release latest` semantics do not apply: /releases/latest skips
# prereleases, so we always walk the releases list (ordered newest first).

GROK_RELEASE_REPO="Yumi-Lab/grok-smartpi"
GROK_RELEASE_API="https://api.github.com/repos/$GROK_RELEASE_REPO/releases"
# GROK_TAG_PREFIX / GROK_ASSET_* are consumed by install.sh (which sources this
# file); shellcheck sees them as unused when linting the lib alone.
# shellcheck disable=SC2034
GROK_TAG_PREFIX="snapshot-armv7-"
# shellcheck disable=SC2034
GROK_ASSET_BIN="grok-armv7"
# shellcheck disable=SC2034
GROK_ASSET_SUM="grok-armv7.sha256"

# Both lookups print "" on any failure and always return 0: install.sh runs
# under pipefail, where curl's own status would otherwise kill it silently
# (exit 35, no message) before its "" check can explain what went wrong.

# grok_latest_tag — print the newest non-draft snapshot-armv7-* tag, "" if none
# (offline, rate-limited, or no release published yet).
grok_latest_tag() {
  { curl -fsSL --max-time 15 "$GROK_RELEASE_API?per_page=20" 2>/dev/null || true; } \
  | python3 -c '
import json, sys
try:
    rels = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for r in rels:
    t = r.get("tag_name", "")
    if t.startswith("snapshot-armv7-") and not r.get("draft"):
        print(t)
        break
'
}

# grok_asset_url TAG ASSET — print the browser_download_url of ASSET in release
# TAG, "" if the release or the asset is missing.
grok_asset_url() {
  { curl -fsSL --max-time 15 "$GROK_RELEASE_API/tags/$1" 2>/dev/null || true; } \
  | python3 -c '
import json, sys
name = sys.argv[1]
try:
    r = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for a in r.get("assets", []):
    if a.get("name") == name:
        print(a.get("browser_download_url", ""))
        break
' "$2"
}
