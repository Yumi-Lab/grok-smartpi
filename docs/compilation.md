# Compilation report — Grok Build for armv7-unknown-linux-gnueabihf

This document is the full technical record behind the `snapshot-armv7-*`
test builds and the official `v*` releases promoted from them: the exact toolchain, every patch and why it exists, what turned
out *not* to be a problem, the qemu test results, and what remains unverified.

## Toolchain (exact)

| component | version | pinned where |
|---|---|---|
| upstream source | `xai-org/grok-build` @ `2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8` | `UPSTREAM_REV` in `.github/workflows/build-armv7.yml` |
| Rust | 1.94.0 (upstream `rust-toolchain.toml` pin) | workflow + upstream toml |
| target | `armv7-unknown-linux-gnueabihf` | everywhere |
| C cross-compiler / linker | zig 0.16.0 (`zig cc -target arm-linux-gnueabihf`) | `ZIG_VERSION` + `ZIG_SHA256` in workflow |
| vendored crate | nono 0.53.0 (crates.io) | `NONO_SHA256` = crates.io registry checksum |
| bundled ripgrep | 15.2.0 `armv7-unknown-linux-gnueabihf` (official release) | `RG_SHA256` in workflow |
| host for the reference build | macOS, Apple Silicon | — |
| CI | `ubuntu-24.04` GitHub runner | workflow |

Why zig as the C toolchain: one static binary replaces the whole
`arm-linux-gnueabihf-gcc` sysroot dance, works identically on macOS and Linux
hosts, and pins glibc compatibility cleanly.

## The one real toolchain trap: cc-rs vs zig target triples

`cc-rs` (used by every `-sys` build script) appends
`--target=armv7-unknown-linux-gnueabihf` to its compiler invocations. zig 0.16
rejects that GNU-style Rust triple — it wants `-target arm-linux-gnueabihf`.
So `tools/cross/zigcc-armv7.sh` is a 15-line `sh` wrapper that **strips any
incoming `-target`/`--target` argument and forces zig's own**:

```sh
case "$a" in
    --target=*) continue ;;
    -target) skip=1; continue ;;
esac
…
exec zig cc -target arm-linux-gnueabihf …
```

`tools/cross/zigar.sh` / `zigranlib.sh` are one-liners to `zig ar` / `zig ranlib`.

## The patches (all under `patches/`, applied with `git apply`)

**`0001-cargo-config-armv7.patch`** — `.cargo/config.toml`:
adds a `[target.armv7-unknown-linux-gnueabihf]` section (linker =
`zigcc-armv7.sh`) and `[env]` entries `CC_/CXX_/AR_/RANLIB_armv7_unknown_linux_gnueabihf`
so cc-rs picks the zig wrappers, plus `GROK_TOOLS_BUNDLE_RG_PATH` /
`GROK_SHELL_BUNDLE_RG_PATH` pointing at `tools/cross/rg-armv7`. Paths are
absolute: the patch carries the literal token `@GROK_ROOT@`, which the build
(CI step "Copy zig wrappers + apply patches") rewrites with
`sed -i "s|@GROK_ROOT@|$PWD|g" .cargo/config.toml` right after applying the
patches.

**`0002-nono-arm-syscalls.patch`** — `Cargo.toml`, `Cargo.lock`,
`third_party/nono/src/sandbox/linux.rs`:
nono 0.53.0 only defines `SYS_OPENAT`/`SYS_OPENAT2` for x86_64 and aarch64, so
the crate does not compile for 32-bit ARM. We vendor the pristine crates.io
crate (sha256-verified at fetch time) to `third_party/nono`, point
`[patch.crates-io]` at it, and add the official EABI numbers:

```rust
#[cfg(target_arch = "arm")]
pub const SYS_OPENAT: i32 = 322;   // __NR_openat
#[cfg(target_arch = "arm")]
pub const SYS_OPENAT2: i32 = 437;  // __NR_openat2
```

The `Cargo.lock` hunk just drops the registry `source`/`checksum` lines for
nono (now a path dependency).

**`0003-pprof-blocklist-cfg.patch`** — `xai-grok-shell-base/src/cpu_profile.rs`:
`pprof::ProfilerGuardBuilder::blocklist` only exists on the 64-bit
architectures pprof can unwind; on armv7 the method is compiled out and the
call is a hard error. The call is now behind the same
`cfg(any(target_arch = "x86_64", "aarch64", "riscv64", "loongarch64"))` gate
pprof itself uses.

**`0004-rlim_t-32bit.patch`** — `xai-grok-shell/src/util/limits.rs`,
`xai-grok-pager/src/app/mermaid_worker.rs`:
`libc::rlim_t` is 64-bit on 64-bit Linux but **32-bit on armv7-glibc**.
Upstream compares/stores it against `u64` caps; on armv7 that is a type
mismatch. The patch does the math in `u64` and casts back to
`libc::rlim_t` when storing — behavior unchanged on 64-bit.

## ripgrep: no linux-arm asset upstream

The build scripts of `xai-grok-tools` and `xai-grok-shell` bundle a ripgrep
binary and auto-download one per platform — but publish/consume no linux-arm
asset. They honor the `GROK_*_BUNDLE_RG_PATH` env override instead, so the
build fetches the **official ripgrep 15.2.0 armv7 release tarball** from
BurntSushi/ripgrep, verifies it against the recorded sha256
(`d8595897…3199`, recorded at first download), and installs the contained
`rg` as `tools/cross/rg-armv7`. No binary is committed to this repo.

## Non-problems (checked, no work needed)

- **aws-lc-sys** — compiles for the target with zig cc, no patch.
- **tikv-jemalloc** — builds and links for armv7; the 32-bit default page
  size needs no `JEMALLOC_SYS_WITH_LG_PAGE` override (those overrides in
  `.cargo/config.toml` only concern 64-bit targets with 16 KB pages).
- **protobuf** — only the host-side `protoc` binary is needed
  (`protobuf-compiler` apt package in CI); no cross-compiled libprotobuf.

## Measured results

Reference build on Apple Silicon (macOS), upstream `2bdd1d6`:

- all four patches apply unchanged (only line offsets moved since `bc7f02e`);
  zero compiler warnings
- `cargo build --release` from an empty target dir: **21m27s** wall clock on
  a host busy with other work (the earlier `bc7f02e` build took ~6 min with a
  warm dependency cache)
- artifact: `target/armv7-unknown-linux-gnueabihf/release/xai-grok-pager`,
  **157,603,700 bytes**, `ELF 32-bit LSB pie executable, ARM, EABI5,
  dynamically linked, interpreter /lib/ld-linux-armhf.so.3, glibc, stripped`,
  `grok 1.0.45 (2bdd1d6a6369)`

qemu smoke tests (docker `linux/arm/v7`, `debian:bookworm-slim`, glibc 2.36,
binfmt via `tonistiigi/binfmt --install arm`) — all PASS:

- `--version`, `--help`
- `doctor`
- headless `-p` without credentials → clean, actionable auth error
- headless `-p` with a bogus `XAI_API_KEY` → real DNS + TLS + HTTP round-trip
  to api.x.ai, HTTP 400 as expected for a bad key

The `--version` smoke test also runs in CI after every build (artifact is
uploaded first, so a smoke failure never costs the binary).

CI reference run for `2bdd1d6` ([run 38205968517](https://github.com/Yumi-Lab/grok-smartpi/actions/runs/38205968517),
`ubuntu-24.04`, cold cache): **20m19s** end to end, all steps green, smoke
test printed `grok 1.0.45 (2bdd1d6a6369)` under qemu. The published
`snapshot-armv7-2bdd1d6` asset is 159,640,132 bytes (CI binary; size differs
from the local reference build) and was re-downloaded and checksum-verified
after publication. The previous snapshot (`bc7f02e`, 1.0.12) took 25m22s on
the same runner.

## Known limits / open points

- **Sandbox under qemu**: the command sandbox is bubblewrap (not Landlock);
  bwrap cannot create user namespaces under qemu-user 32-bit emulation and
  fails cleanly. On a Smart Pi One (DietPi trixie) an unprivileged `bwrap`
  does create user namespaces; grok's own sandboxed command path still needs
  an authenticated session to be exercised.
- **Real hardware**: install, OTA update, TUI, headless round-trip and RAM are
  measured on two Smart Pi One boards (README, "Measured status"). A real
  authenticated session is not: no xAI key was available.
- **Mainland China**: api.x.ai is blocked and GitHub is intermittent; see the
  README section "From mainland China".
- **Upstream drift**: `UPSTREAM_REV` is pinned. Bumping it may break a patch;
  `git apply` failing loudly in CI is the intended alarm.

## Reproduce locally

```sh
git clone https://github.com/Yumi-Lab/grok-smartpi
git init grok-build-armv7 && cd grok-build-armv7
git remote add origin https://github.com/xai-org/grok-build
git fetch --depth 1 origin 2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8
git checkout FETCH_HEAD

# third-party inputs (sha256-pinned, see the workflow env block)
curl -fsSL https://static.crates.io/crates/nono/nono-0.53.0.crate -o /tmp/nono.crate
mkdir -p third_party && tar xzf /tmp/nono.crate -C third_party && mv third_party/nono-0.53.0 third_party/nono
# … ripgrep 15.2.0 armv7 → tools/cross/rg-armv7 (same URLs/checksums as CI)

cp -r ../grok-smartpi/tools/cross tools/cross && chmod +x tools/cross/*.sh
for p in ../grok-smartpi/patches/*.patch; do git apply -v "$p"; done
sed -i "s|@GROK_ROOT@|$PWD|g" .cargo/config.toml   # macOS: sed -i ''

cargo build -p xai-grok-pager-bin --release --target armv7-unknown-linux-gnueabihf
```

Requirements on the host: Rust 1.94.0 with the armv7 target, zig 0.16 on
`PATH`, `protoc`.
