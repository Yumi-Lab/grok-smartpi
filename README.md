# grok-smartpi

**Grok Build — xAI's agentic coding CLI — cross-compiled for 32-bit ARM (armv7l)**, targeting the Yumi Smart Pi One (Allwinner H3) and similar armhf boards.

Upstream ([xai-org/grok-build](https://github.com/xai-org/grok-build), Rust, Apache 2.0) publishes no 32-bit ARM build. This repo carries the minimal patch set that makes the tree compile for `armv7-unknown-linux-gnueabihf`, plus a GitHub Action that reproduces the build and publishes snapshot prereleases, plus an installer that follows the `Yumi-Lab/*-smartpi` OTA contract.

## Install

On the board (armv7l, Debian/Armbian, glibc):

```sh
curl -fsSL https://raw.githubusercontent.com/Yumi-Lab/grok-smartpi/main/install.sh | bash
```

- First install needs root/sudo (to create `/opt/grok` and hand it to your user). Every update after that runs unprivileged as the owner of `/opt/grok` — re-running `install.sh` **is** the updater (no-op when already current).
- `GROK_VERSION=snapshot-armv7-<sha>` pins a specific release; `GROK_FORCE=1` forces a reinstall; `GROK_CPUS=0,1` limits the launcher to specific cores.
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
6. On demand (`workflow_dispatch` with `release: true`, or a pushed `snapshot-armv7-*` tag), publish a **prerelease** tagged `snapshot-armv7-<short upstream sha>` with `grok-armv7` + `grok-armv7.sha256`. Snapshots never use upstream's own version numbers.

Full toolchain details, the reason for every patch, and the non-problems: [docs/compilation.md](docs/compilation.md).

## Target prerequisites

- `armv7l` CPU (checked by `install.sh`)
- glibc userland — **2.36 tested** (Debian bookworm); musl unsupported (dynamic ELF, interpreter `/lib/ld-linux-armhf.so.3`)
- `bubblewrap` + a kernel with `CONFIG_USER_NS` for the command sandbox (the binary runs without it, unsandboxed — the installer warns)
- RAM: **not measured on hardware.** The binary is 143,540,788 bytes; on a 512 MB–1 GB H3 board, watch memory pressure. `GROK_CPUS` + `nice` in the launcher help keep the board responsive.

## Measured status

| | |
|---|---|
| Compiles for `armv7-unknown-linux-gnueabihf` | yes — `grok 1.0.12 (bc7f02eddd3d)`, upstream `bc7f02e` |
| `cargo check` (fresh tree, Apple Silicon host) | 3m19s |
| `cargo build --release` (Apple Silicon host) | ~6 min |
| Artifact | 143,540,788 bytes, `ELF 32-bit LSB pie executable, ARM, EABI5, dynamically linked, glibc, stripped` |
| qemu smoke (`linux/arm/v7`, glibc 2.36) | `--version` PASS, `--help` PASS, `doctor` PASS, headless `-p` without key → clean auth error PASS, bogus `XAI_API_KEY` → real DNS+TLS+HTTP round-trip to api.x.ai (HTTP 400, as expected) PASS |
| Sandbox under qemu | bubblewrap fails to create user namespaces under qemu-user — known emulation artifact, fails cleanly |
| Real hardware (Smart Pi One) | **NOT yet validated**: TUI, real auth, H3 performance |

No number above is estimated; everything listed was measured on the build host or under qemu. Treat this as a build pipeline awaiting hardware validation, not a finished port.

## License

Apache 2.0, aligned with upstream. The patches and scripts in this repo are released under the same terms; the upstream codebase retains its own copyright and license.
