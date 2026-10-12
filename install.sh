#!/usr/bin/env bash
# grok-smartpi — "Grok Build" (xAI's Rust agentic CLI) cross-compiled for
# 32-bit ARM (armv7l), targeting the Yumi Smart Pi One (Allwinner H3).
#
# One-line install (and update — re-running IS the updater):
#   curl -fsSL https://raw.githubusercontent.com/Yumi-Lab/grok-smartpi/main/install.sh | bash
#
# What it does:
#   * resolves the newest `snapshot-armv7-*` prerelease of this repo
#     (or GROK_VERSION=<tag> to pin one);
#   * downloads grok-armv7 + grok-armv7.sha256 into /var/tmp (never /tmp —
#     tmpfs on these boards), verifies the checksum;
#   * installs under /opt/grok:
#       /opt/grok/grok-bin   the real binary (~160 MB)
#       /opt/grok/grok       launcher (taskset/nice via GROK_CPUS)
#       /opt/grok/VERSION    the installed release tag (update contract)
#       /opt/grok/bin/grok-check-update   OTA probe (one JSON line)
#   * symlinks grok + grok-check-update into /usr/local/bin when privileged.
#
# Privilege model: root (or passwordless/interactive sudo) is needed ONLY for
# the first install, to create /opt/grok and hand it to the invoking user.
# Re-runs must be done by the owner of /opt/grok and need no sudo — which is
# how the Yumi AI Gateway updates unprivileged.
#
# OTA contract (shared by every Yumi-Lab/*-smartpi repo):
#   * re-running this script IS the update (no-op exit when already current);
#   * `grok-check-update` prints {"cli":"grok","installed":…,"latest":…,
#     "update_available":…} — what the gateway polls for its update badge;
#   * release endpoints + version parsing live ONLY in lib/grok-release.sh.
#
# Env knobs:
#   GROK_VERSION=<tag>   install this exact release tag instead of the latest
#   GROK_FORCE=1         reinstall even when already current
#   GROK_CPUS=0,1        core list for the launcher (default: all cores)
set -euo pipefail

log()  { printf '\033[1;36m[grok-smartpi]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[grok-smartpi]\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m[grok-smartpi]\033[0m %s\n' "$*" >&2; exit 1; }

# --- 0. Target guards ---------------------------------------------------------
[ "$(uname -m)" = "armv7l" ] || fail "This script targets armv7l (detected: $(uname -m)). On 64-bit, install the official release from https://github.com/xai-org/grok-build"
command -v curl    >/dev/null || fail "curl is required"
command -v python3 >/dev/null || fail "python3 is required (release JSON parsing)"
command -v sha256sum >/dev/null || fail "sha256sum is required (coreutils)"

# The binary is dynamically linked against glibc (interpreter
# /lib/ld-linux-armhf.so.3) — musl systems (Alpine) cannot run it.
# getconf, not `ldd --version | head -1`: Debian's ldd is a bash script that
# dies of SIGPIPE once head exits, and pipefail turned that into a false
# "no glibc" on 47/50 runs on a real Smart Pi. musl's getconf rejects the key.
GLIBC_VER="$(getconf GNU_LIBC_VERSION 2>/dev/null || true)"
case "$GLIBC_VER" in
  "glibc "*) GLIBC_VER="${GLIBC_VER#glibc }" ;;
  *) fail "glibc not detected — this build needs a glibc userland (Debian/Armbian), musl is unsupported." ;;
esac
# Built against bookworm-era symbols; glibc >= 2.36 verified under qemu.
G_MAJ="${GLIBC_VER%%.*}"; G_MIN="${GLIBC_VER#*.}"; G_MIN="${G_MIN%%[!0-9]*}"
if [ "$G_MAJ" -lt 2 ] || { [ "$G_MAJ" -eq 2 ] && [ "${G_MIN:-0}" -lt 36 ]; }; then
  warn "glibc $GLIBC_VER < 2.36 — untested, the binary may refuse to start."
fi

# The sandbox uses bubblewrap (user namespaces), not Landlock. Warn only.
if ! command -v bwrap >/dev/null 2>&1; then
  warn "bubblewrap (bwrap) not found — the command sandbox will be unavailable."
  warn "Install it when you can:  apt-get install bubblewrap"
fi

RAW="https://raw.githubusercontent.com/Yumi-Lab/grok-smartpi/main"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd || true)"

# Fetch a repo file: local copy when run from a clone, otherwise raw GitHub.
fetch_repo() { # $1 repo-relative path, $2 destination, $3 mode (default 755)
  local mode="${3:-755}"
  if [ -n "$HERE" ] && [ -f "$HERE/$1" ]; then
    install -m"$mode" "$HERE/$1" "$2"
  else
    local t; t="$(mktemp /var/tmp/grok-fetch.XXXXXX)"
    curl -fsSL "$RAW/$1" -o "$t" && install -m"$mode" "$t" "$2"; local rc=$?
    rm -f "$t"; return $rc
  fi
}

SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO="sudo"
can_root() { [ "$(id -u)" -eq 0 ] || sudo -n true 2>/dev/null || { [ -t 1 ] && command -v sudo >/dev/null; }; }

OPT="/opt/grok"
BIN_REAL="$OPT/grok-bin"
LAUNCHER="$OPT/grok"
VERSION_FILE="$OPT/VERSION"

# --- 1. Install prefix --------------------------------------------------------
# First install creates /opt/grok and hands it to the invoking (non-root) user,
# so every later update runs unprivileged as that user.
if [ ! -d "$OPT" ]; then
  can_root || fail "First install needs root (or sudo) to create $OPT. Re-run with sudo."
  OWNER="${SUDO_USER:-$(id -un)}"
  log "Creating $OPT (owner: $OWNER — later updates run unprivileged as $OWNER)"
  $SUDO mkdir -p "$OPT/bin" "$OPT/lib"
  $SUDO chown -R "$OWNER:$OWNER" "$OPT"
fi
[ -w "$OPT" ] || fail "$OPT is not writable by $(id -un) — re-run as its owner (updates need no root)."
mkdir -p "$OPT/bin" "$OPT/lib"

# --- 2. Shared release library + target tag -----------------------------------
fetch_repo lib/grok-release.sh "$OPT/lib/grok-release.sh" 644 \
  || fail "cannot install lib/grok-release.sh"
# shellcheck source=lib/grok-release.sh
. "$OPT/lib/grok-release.sh"

TAG="${GROK_VERSION:-}"
if [ -z "$TAG" ]; then
  TAG="$(grok_latest_tag)"
  [ -n "$TAG" ] || fail "no snapshot-armv7-* release found on $GROK_RELEASE_REPO (offline? none published yet?)"
fi
case "$TAG" in
  "$GROK_TAG_PREFIX"*) : ;;
  *) fail "refusing tag '$TAG' — expected $GROK_TAG_PREFIX*" ;;
esac
CURRENT="$(cat "$VERSION_FILE" 2>/dev/null || true)"
log "Target release: $TAG (installed: ${CURRENT:-none})"

# --- 3. Fast path --------------------------------------------------------------
if [ "$CURRENT" = "$TAG" ] && [ -x "$BIN_REAL" ] && [ -z "${GROK_FORCE:-}" ]; then
  log "grok $TAG already installed — nothing to do (GROK_FORCE=1 to reinstall)."
else
  # --- 4. Download + verify (into /var/tmp, never /tmp: tmpfs on these boards) --
  DL="$(mktemp -d /var/tmp/grok-smartpi.XXXXXX)"
  trap 'rm -rf "$DL"' EXIT
  URL_BIN="$(grok_asset_url "$TAG" "$GROK_ASSET_BIN")"
  URL_SUM="$(grok_asset_url "$TAG" "$GROK_ASSET_SUM")"
  [ -n "$URL_BIN" ] && [ -n "$URL_SUM" ] || fail "release $TAG is missing $GROK_ASSET_BIN / $GROK_ASSET_SUM"
  # The 77-byte checksum first: from China a GitHub hop can drop at any time,
  # and failing here costs a second, not the hour the binary takes there.
  curl -fsSL -o "$DL/$GROK_ASSET_SUM" "$URL_SUM" || fail "download failed: $URL_SUM"
  log "Downloading $GROK_ASSET_BIN (~160 MB — this takes a while on a pad's WiFi)…"
  curl -fSL -C - --progress-bar -o "$DL/$GROK_ASSET_BIN" "$URL_BIN" || fail "download failed: $URL_BIN"
  ( cd "$DL" && sha256sum -c "$GROK_ASSET_SUM" ) || fail "sha256 mismatch — aborted, nothing installed."

  # --- 5. Install --------------------------------------------------------------
  install -m755 "$DL/$GROK_ASSET_BIN" "$BIN_REAL.new"
  mv "$BIN_REAL.new" "$BIN_REAL"
  cat > "$LAUNCHER" <<'EOF'
#!/bin/sh
# Grok Build on armv7l — managed by grok-smartpi/install.sh.
# Re-run install.sh to update. Do NOT use any upstream self-updater:
# there is no official 32-bit ARM release.
#
#   GROK_CPUS=0,1 grok …    limit the agent to 2 cores (default: all cores)
CPUS="${GROK_CPUS:-0,1,2,3}"
if command -v taskset >/dev/null 2>&1; then
  exec taskset -c "$CPUS" nice -n 5 /opt/grok/grok-bin "$@"
fi
exec nice -n 5 /opt/grok/grok-bin "$@"
EOF
  chmod 755 "$LAUNCHER"
  printf '%s\n' "$TAG" > "$VERSION_FILE"
fi

# --- 6. OTA probe --------------------------------------------------------------
fetch_repo bin/grok-check-update "$OPT/bin/grok-check-update" \
  || warn "grok-check-update not installed (non-fatal)."

# A root run (`sudo bash`, or a root re-run) writes root-owned files into the
# owner's tree; give them back, or the owner's next unprivileged update dies on
# `cat > $LAUNCHER` after the download.
if [ "$(id -u)" -eq 0 ]; then chown -R "$(stat -c %U:%G "$OPT")" "$OPT"; fi

# --- 7. PATH (symlinks when privileged, hint otherwise) ------------------------
if can_root; then
  $SUDO ln -sf "$LAUNCHER" /usr/local/bin/grok
  [ -x "$OPT/bin/grok-check-update" ] && $SUDO ln -sf "$OPT/bin/grok-check-update" /usr/local/bin/grok-check-update
  hash -r 2>/dev/null || true
elif ! command -v grok >/dev/null 2>&1; then
  warn "not root: add $OPT to your PATH (export PATH=\"$OPT:\$PATH\") or re-run once with sudo for /usr/local/bin symlinks."
fi

# --- 8. Sanity check ------------------------------------------------------------
TO=""; command -v timeout >/dev/null && TO="timeout 30"
VER_OUT="$($TO "$LAUNCHER" --version 2>/dev/null || true)"
[ -n "$VER_OUT" ] || warn "grok --version gave no answer in 30 s — retry on an idle board."

cat <<MSG

✔ Install complete — grok $TAG${VER_OUT:+
  $VER_OUT}

Usage:
    grok                        interactive agent (TUI)
    grok -p "question"          one-shot, non-interactive
    grok doctor                 validate the setup
    grok --version              sanity check

    GROK_CPUS=0,1 grok …        limit the running agent to 2 cores

Auth:
    needs an xAI API key — export XAI_API_KEY=… (see README).

Update:
    grok-check-update           →  {"cli":"grok","installed":…,"latest":…,"update_available":…}
    re-run install.sh           installs the newest snapshot (no-op when current)

Known limits (see README):
    the sandbox needs bubblewrap + user namespaces; hardware validation
    (TUI, real auth, H3 performance) is still pending — this build has only
    been smoke-tested under qemu.
MSG
