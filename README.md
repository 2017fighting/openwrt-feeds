# openwrt-feeds

A self-built **OpenWrt source feed** whose binary packages are compiled with the
OpenWrt SDK in GitHub Actions and published as a **signed APK feed** to GitHub
Pages.

- **OpenWrt version:** 25.12.4 (APK package manager)
- **Architectures:** `x86_64`
- **Live binary feed:** <https://2017fighting.github.io/openwrt-feeds/25.12.4/>
- **Packages:** `punchd` — the router side of the declared CGNAT punch: it pulls
  the desired `Punch` list from the cluster, keeps one `natmap` child per punch
  and renders the DNAT into fw4's `ruleset-post`. Built here from a
  commit-pinned <https://github.com/2017fighting/punch>. Everything else it needs
  (`natmap`, `ca-bundle`) comes from OpenWrt's own feeds.
- **Quick install:** `sh -c "$(wget -O- https://2017fighting.github.io/openwrt-feeds/feed.sh)"`

This repository is **both** the source feed (OpenWrt package `Makefile`s on
`main`) and the generator of the published binary feed.

## Quick install

On the device, run the one-shot installer — it detects the arch and release,
installs the signing key, registers the feed, and runs `apk update`:

```sh
sh -c "$(wget -O- https://2017fighting.github.io/openwrt-feeds/feed.sh)"
```

Then install punchd and hand it the one thing a package must not carry:

```sh
apk add punchd

# The bearer token is device-local (0600) and never packaged — shape:
# /etc/punch/token.example. The service stays disabled until you place it.
install -m 600 /dev/null /etc/punch/token
vi /etc/punch/token
/etc/init.d/punchd enable && /etc/init.d/punchd start
```

`apk add punchd` auto-installs its runtime deps from the device's own repos:
`natmap` (the binary punchd runs, one child per punch) and `ca-bundle` (system
roots for its HTTPS calls to the cluster). The port declarations themselves are
not on the router at all — they live in the cluster as `Punch` CRs.

Prefer to read it first? See [`feed.sh`](feed.sh), mirrored on [the Pages
site](https://2017fighting.github.io/openwrt-feeds/feed.sh). It is apk-only and
refuses opkg-only releases.

## Manual install

The steps below are what `feed.sh` automates, in case you prefer to do them by
hand. (Only `x86_64` is published; the matrix previously carried
`aarch64_generic` — drop it from the repositories line if you still have an
armsr/armv8 device pointed at an old slice.)

```sh
# 1. Trust this feed's signing key (apk EC public key; apk reads all of /etc/apk/keys/)
wget -O /etc/apk/keys/2017fighting.pem \
  https://raw.githubusercontent.com/2017fighting/openwrt-feeds/main/keys/2017fighting.pem

# 2. Add the repository (point at the SIGNED INDEX; apk reads a *.adb URL
#    directly — the bare directory makes it probe legacy APKINDEX.tar.gz and fail)
echo 'https://2017fighting.github.io/openwrt-feeds/25.12.4/x86_64/packages.adb' \
  >> /etc/apk/repositories

# 3. Install (natmap + ca-bundle come from the device's own repos)
apk update
apk add punchd

# 4. Place the device-local token, then enable + start (procd)
install -m 600 /dev/null /etc/punch/token
vi /etc/punch/token        # shape: /etc/punch/token.example
/etc/init.d/punchd enable
/etc/init.d/punchd start
```

Always point the feed at the **signed index file** (`packages.adb`), not the
directory — the bare directory makes apk probe the legacy `<arch>/APKINDEX.tar.gz`
and warn (`unexpected end of file`). The same `packages.adb` URL is what a custom
firmware image (ASU / imagebuilder) consumes as an additional feed.

## Signing

Only the repository index (`packages.adb`) is signed — apk never signs
individual `.apk` files. The signature is an **openssl EC (prime256v1 / NIST
P-256)** signature embedded directly in `packages.adb` (there is no separate
`.sig` file), produced with `apk adbsign --sign-key` — exactly how official
OpenWrt signs its apk repos.

- Public key: [`keys/2017fighting.pem`](keys/2017fighting.pem)
  (`-----BEGIN PUBLIC KEY-----`) — install into `/etc/apk/keys/`.
- Private key (`private-key.pem`): stored only as the GitHub Actions secret
  `APK_SIGN_KEY`; never committed. The key is permanent — rotating it is a
  breaking change (every installed device must add the new public key).

## How it is built

`.github/workflows/build.yml` runs on every push to `main` (and via manual
dispatch):

1. Download + extract the matching OpenWrt SDK.
2. Register this repo as a feed (`src-link`) inside the SDK, plus the SDK's
   `base` feed (punchd's `+firewall4` resolves there); `packages` stays
   unregistered, so `natmap`/`ca-bundle` remain runtime-only deps (see
   [`CLAUDE.md`](CLAUDE.md) for why).
3. Borrow the `golang` toolchain from the packages repo into this feed at CI
   time, then compile `punchd`
   (`make package/feeds/<feed>/punchd/compile`).
4. Generate + sign the index (`make package/index` → `packages.adb`, signed
   in-place by `apk adbsign` — no separate `.sig`).
5. Publish the whole site to GitHub Pages (`actions/deploy-pages`).

## Repository layout

```
net/punchd/          # punchd — declared-CGNAT punch agent (Go: natmap children + fw4 include)
docs/adr/            # decision records (0002 retires the old natmapt/stuntman/mihomo packages)
keys/                # apk EC public signing key (committed; private key is a CI secret)
tooling/             # build plan + keygen + Pages index helpers
feed.sh              # one-shot on-device installer (key + feed + apk update)
feeds.config         # supported feeds (version x arch) — drives the build matrix
.github/workflows/   # CI: build, sign, publish
```

## Adding a package

Drop `net/<pkg>/Makefile` (standard OpenWrt package definition) at the repo
root, then add the directory name to `COMPILE_ORDER` (and, if it ships an apk
under a new name, to the `cmd_verify` glob list) in
[`tooling/build-plan.sh`](tooling/build-plan.sh) — that module owns install,
compile order and verification, and `tooling/tests/` asserts it against the
Makefiles. Nothing goes into `build.yml` by hand. It is **not** automatic — the
SDK ships no core package sources and only builds feed packages, so anything
needing a core lib or a standard runtime dep needs the patterns described in
[`CLAUDE.md`](CLAUDE.md) (runtime-only deps via the unregistered `packages`
feed; core libs pulled into this feed at CI time).

## Adding a version or architecture

Add an entry to [`feeds.config`](feeds.config). The matrix in
`build.yml` reads it with `jq`, and the SDK tarball URL is derived from the
entry.

## License

`punchd` is built from <https://github.com/2017fighting/punch> — **MIT** since `v0.1.0`,
the commit the pin points at (before that the repository had no `LICENSE`, which is
why this feed asserted none). The apk therefore declares `PKG_LICENSE:=MIT` and
`PKG_LICENSE_FILES:=LICENSE`. The `golang` toolchain is borrowed at CI time
from <https://github.com/openwrt/packages> (**BSD-3-Clause**) to build it; the
apk feed itself publishes only `punchd`.
