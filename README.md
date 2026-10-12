# grok-smartpi

**Grok Build — xAI's agentic coding CLI — cross-compiled for 32-bit ARM (armv7l)**, targeting the Yumi Smart Pi One (Allwinner H3) and similar armhf boards.

Upstream ([xai-org/grok-build](https://github.com/xai-org/grok-build), Rust, Apache 2.0) publishes no 32-bit ARM build. This repo carries the minimal patch set that makes the tree compile for `armv7-unknown-linux-gnueabihf`, plus a GitHub Action that reproduces the build and publishes test snapshots, plus an installer pinned to the official release validated on a real Smart Pi, following the `Yumi-Lab/*-smartpi` OTA contract.

## Install

On the board (armv7l, Debian/Armbian, glibc):

```sh
curl -fsSL https://raw.githubusercontent.com/Yumi-Lab/grok-smartpi/main/install.sh | bash
```

- **Pinned.** The installer installs `GROK_PIN` from [lib/grok-release.sh](lib/grok-release.sh) — currently **v1.0.45** (grok 1.0.45) — and nothing else. A new upstream commit or test snapshot never reaches a board on its own.
- First install needs root/sudo (to create `/opt/grok` and hand it to your user). Every update after that runs unprivileged as the owner of `/opt/grok` — re-running `install.sh` **is** the updater (no-op when already current).
- `GROK_VERSION=<tag>` installs another release instead of the pin (e.g. a `snapshot-armv7-<sha>` test build on one board); `GROK_FORCE=1` forces a reinstall; `GROK_CPUS=0,1` limits the launcher to specific cores.
- Downloads go to `/var/tmp` (never `/tmp`, which is tmpfs on these boards), and every binary is verified against the `.sha256` published next to it.

## Usage

```sh
grok                        # interactive agent (TUI)
grok -p "question"          # one-shot, non-interactive
grok doctor                 # validate the setup
grok-check-update           # {"cli":"grok","installed":…,"latest":…,"update_available":…}
```

Auth requires an xAI API key: `export XAI_API_KEY=…`.

## How it works

1. Clone upstream at the pinned revision (`UPSTREAM_REV` in the workflow).
2. Fetch two pinned third-party inputs, sha256-verified: the `nono` 0.53.0 crate from crates.io (vendored to `third_party/nono`) and the official ripgrep 15.2.0 armv7 binary from BurntSushi/ripgrep releases (no committed binaries in this repo).
3. Copy the `tools/cross/` zig wrappers in, apply `patches/*.patch` with `git apply` — a patch that stops applying **fails the build loudly**, which is the signal that upstream moved.
4. `cargo build -p xai-grok-pager-bin --release --target armv7-unknown-linux-gnueabihf` with zig 0.16 as the C cross-compiler/linker.
5. Upload the artifact, then smoke-test it under qemu (`linux/arm/v7`, Debian bookworm = glibc 2.36). A smoke failure posts a notice but never costs the artifact.
6. On demand (`workflow_dispatch` with `release: true`, or a pushed `snapshot-armv7-*` tag), publish a **prerelease** tagged `snapshot-armv7-<short upstream sha>` with `grok-armv7` + `grok-armv7.sha256`. Snapshots are test builds: boards only get them with `GROK_VERSION`.
7. A snapshot that passes on a real board is promoted, byte for byte, to an **official release** `v<grok version>` (see below), and `GROK_PIN` moves to it.

Full toolchain details, the reason for every patch, and the non-problems: [docs/compilation.md](docs/compilation.md).

## Moving to a newer grok (maintainers)

1. Bump `UPSTREAM_REV` in the workflow, push, and push the tag `snapshot-armv7-<short sha>`: CI builds and publishes the snapshot (or fails loudly if a patch no longer applies).
2. On one board: `curl -fsSL https://raw.githubusercontent.com/Yumi-Lab/grok-smartpi/main/install.sh | GROK_VERSION=snapshot-armv7-<short sha> bash`, then check `grok --version`, the TUI, and a real `grok -p`.
3. Set `GROK_PIN=v<grok version>` in [lib/grok-release.sh](lib/grok-release.sh), commit, tag the commit `v<grok version>`, and push **the tag only**.
4. Create the official release on that tag (latest, not prerelease) with the snapshot's `grok-armv7` + `grok-armv7.sha256` unchanged, plus `grok-<version>-source.zip` — the patched upstream tree from [Reproduce locally](docs/compilation.md#reproduce-locally), before `cargo build`, without `.git`. GitHub adds this repo's own source zip, whose `install.sh` is locked to that release.
5. Push `main`. Every board's `grok-check-update` now reports `update_available: true`; re-running the installer moves it. (Pushing `main` before the release exists would point boards at a missing download.)

## Target prerequisites

- `armv7l` CPU (checked by `install.sh`)
- glibc userland — tested on **2.36** (qemu, bookworm), **2.41** (DietPi trixie) and **2.43** (Debian forky) on hardware; musl unsupported (dynamic ELF, interpreter `/lib/ld-linux-armhf.so.3`)
- `bubblewrap` + a kernel with `CONFIG_USER_NS` for the command sandbox (the binary runs without it, unsandboxed — the installer warns). On a DietPi trixie Smart Pi One, `bwrap` creates user namespaces as an unprivileged user.
- Disk: ~160 MB under `/opt/grok`, plus the same again in `/var/tmp` during an update.
- RAM, peak RSS measured on a 1 GB Smart Pi One: `--version` 14 MB, idle TUI 91 MB, one headless request 110 MB. `GROK_CPUS` + `nice` in the launcher keep the board responsive.
- Network: `api.x.ai` for the agent, GitHub for install and updates. From mainland China, neither works reliably without a tunnel — see below.

## From mainland China

Measured from a Smart Pi One on a Hangzhou fibre line (2026-10-12):

- **`api.x.ai` is blocked.** The local DNS answers with a Facebook address, and the real Cloudflare address times out when reached directly. `grok` then hangs with no output (killed after 180 s). With `api.x.ai` pinned in `/etc/hosts` and its addresses routed through a VPN tunnel exiting in Europe, the same headless request completes in ~10 s.
- **GitHub comes and goes.** `api.github.com`, `github.com` and `raw.githubusercontent.com` were each reachable in some windows and dead in others within the same hour. When the path held, the 145 MB binary came down at ~41 KB/s (59 min). When a hop drops, the installer stops with an explicit message; re-run it once the path is back, or route GitHub through the tunnel as well.

## Measured status

| | |
|---|---|
| Compiles for `armv7-unknown-linux-gnueabihf` | yes — `grok 1.0.45 (2bdd1d6a6369)`, upstream `2bdd1d6` (patches unchanged since `bc7f02e`) |
| `cargo build --release` (Apple Silicon host, empty target dir) | 21m27s |
| Local artifact | 157,603,700 bytes, `ELF 32-bit LSB pie executable, ARM, EABI5, dynamically linked, glibc, stripped` |
| CI build (ubuntu-24.04, cold cache) | 20m19s (tag run, publishes) / 30m10s (`main` run) — [run 38205968517](https://github.com/Yumi-Lab/grok-smartpi/actions/runs/38205968517) |
| Official release `v1.0.45` | the `snapshot-armv7-2bdd1d6` binary promoted byte for byte: 159,640,132 bytes, sha256 `84094bbb…9a3175`, re-downloaded and checksum-verified |
| qemu smoke (`linux/arm/v7`, glibc 2.36) | `--version` PASS (also in CI), `--help` PASS, `doctor` PASS, headless `-p` without key → clean auth error PASS, bogus `XAI_API_KEY` → real DNS+TLS+HTTP round-trip to api.x.ai (HTTP 400, as expected) PASS |
| Sandbox under qemu | bubblewrap fails to create user namespaces under qemu-user — known emulation artifact, fails cleanly |
| Install on hardware (Smart Pi One, DietPi trixie, 991 MB RAM, 4G uplink) | first install through the sudo path, from the published release: PASS (20 min, checksum OK) |
| OTA update on hardware | `grok-check-update` → `update_available: true`; the gateway's service user re-runs the one-liner unprivileged → 1.0.12 → 1.0.45 in 23.6 min; probe back to `false`: PASS |
| Runtime on hardware (H3, 1.0.45) | `--version` 0.1 s; `doctor` 0.1 s; TUI renders (login screen) and exits cleanly on Ctrl+Q; headless `-p` with a bogus key → real round-trip to api.x.ai, HTTP 400 in 7.7–8.7 s: PASS |
| Second board (Hangzhou, Debian forky, glibc 2.43) | binary runs (`--version`, `doctor`, auth error); api.x.ai only through a tunnel — see [From mainland China](#from-mainland-china) |
| **Not validated** | a real authenticated session (no xAI key was available for the tests), and grok's sandboxed command execution on hardware |

No number above is estimated: each was measured on the build host, under qemu, or on two Smart Pi One boards (France and Hangzhou).

## License

Apache 2.0, aligned with upstream. The patches and scripts in this repo are released under the same terms; the upstream codebase retains its own copyright and license.
