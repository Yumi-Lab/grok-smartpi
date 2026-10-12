#!/bin/sh
# grok-release.sh — sourced by install.sh AND bin/grok-check-update: the one
# place that decides which grok release a board installs, and where it lives.
#
# GROK_PIN — the official release validated on a real Smart Pi. The installer
#   installs it and nothing else: the snapshot-armv7-* prereleases CI publishes
#   on every upstream bump are test builds and never reach a board on their own.
#   To move up: test a snapshot on a pad with
#   `GROK_VERSION=snapshot-armv7-<sha> bash install.sh`, promote it to an
#   official release, then bump GROK_PIN here; every pad's update badge
#   (grok-check-update reads this line on GitHub) lights up.
#
# Every release carries grok-armv7 (ELF 32-bit, glibc) and grok-armv7.sha256.
# shellcheck disable=SC2034  # read by install.sh / grok-check-update
GROK_PIN=v1.0.45
GROK_RELEASE_REPO="Yumi-Lab/grok-smartpi"
GROK_DOWNLOAD="https://github.com/$GROK_RELEASE_REPO/releases/download"
GROK_RAW="https://raw.githubusercontent.com/$GROK_RELEASE_REPO/main"
GROK_ASSET_BIN="grok-armv7"
GROK_ASSET_SUM="grok-armv7.sha256"
GROK_VERSION="${GROK_VERSION:-$GROK_PIN}"
