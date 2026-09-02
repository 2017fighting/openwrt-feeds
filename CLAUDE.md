# openwrt-feeds

Self-built OpenWrt **source feed** (package Makefiles) + a GitHub Actions pipeline
that compiles, signs, and publishes a **binary apk feed** to GitHub Pages.

## Build / test

- There is **no local build**. Compilation runs in CI via the OpenWrt SDK
  (`.github/workflows/build.yml`). Push to `main` or `workflow_dispatch` triggers it.
- OpenWrt **25.12.4 is APK-based** (`.apk` + `packages.adb`). Only the index is signed.
- Host-side tests (no SDK needed): `sh tooling/tests/run.sh` — covers the natmapt section status store and the build plan derivation; CI runs it in a fast `Host tests` job before the matrix build.

## Local helpers

- `sh tooling/gen-key.sh`            # one-time openssl EC apk signing keypair (privkey -> secret APK_SIGN_KEY)
- `sh tooling/make-index.sh site`    # regenerate Pages index.html (optional `SITE_BASE=...`)
- `sh tooling/build-plan.sh plan`    # dry-run print of everything CI will build (derived from the Makefiles)

## Layout / conventions

- `net/<pkg>/Makefile`     — apk package definitions (the source feed)
- `feeds.config`           — JSON; drives the build matrix (`openwrt_version` x `arch`). Edit here to add an arch.
- `keys/2017fighting.pem` — apk signing public key (EC PEM `-----BEGIN PUBLIC KEY-----`, committed); the private key is the `APK_SIGN_KEY` secret
- `.github/workflows/`     — `build.yml` (build+sign+deploy), `keygen.yml` (one-time keypair)
- Adding a package: drop `<category>/<pkg>/Makefile` at the repo root; push.
- Adding an arch: append to `feeds.config` (the workflow reads it via `jq`).
- `feed.sh`              — on-device installer (adds apk key + feed, runs `apk update`); copied to the Pages site root by `build.yml`.

## Notes

- `mosdns` is pure Go (CGO=0), cross-compiled with host Go, pinned to **v5.5.0**.
  Its Go source is **not** in this repo; the SDK fetches it by tag (CI pre-places it in `dl/`).
- In CI: run `make defconfig` before package compile (no TTY); pre-fetch the source into `dl/`.
- `PKGARCH` auto-detects the SDK target arch; `MOSDNS_GOARCH` is passed from the matrix.
- `natmapt` is a **C binary** (upstream <https://github.com/heiher/natmap>), compiled with the SDK's musl/gcc toolchain. Its release tarball (`natmap-<ver>.tar.xz`) is pre-fetched into `dl/`. `DEPENDS:=+curl +jsonfilter +bash` are **runtime-only** (see SDK limitation) — the device auto-installs them from its own repos on `apk add natmapt`. The single `net/natmapt` Makefile also defines 5 `PKGARCH:=all` script sub-packages; `natmapt/compile` builds them all (splits share the source dir — no per-split compile targets).
- `natmapt` status interface: the **section status store** (`net/natmapt/files/status.sh` → `/usr/lib/natmap/status.sh`) owns everything — schema, paths, filename sanitizing, atomic writes, cleanup. `natmap-update.sh` (the natmap `-e` hook; the init exports `SECTIONID`/`COMMENT`/`STATUS_NAME` into it) calls `status_publish <sid> <comment> <name> <pid> + 6 mapping fields`; `/etc/init.d/natmap` calls `status_clear [sid]` (removes **every** file of that section). Consumer-facing contract (frozen — do not change in place): public per-name file `/www/natmap/<name|SECTIONID>.json`, served by uhttpd over HTTP at `/natmap/<name>.json` as a query interface for other programs. The normative schema/URL/perm statement is the `status.sh` header; host-side tests in `tooling/tests/`.
- `stuntman-client` (`net/stuntman/`, vendored from <https://github.com/muink/openwrt-stuntman>) provides `stunclient` for `luci-app-natmapt`'s NAT-type test. C++ target binary; `PKG_BUILD_DEPENDS:=boost/host` (heavier host-boost build); `+libopenssl` (both pulled into THIS feed at CI time — see below). `luci-app-natmapt` depends on `+natmapt +coreutils-timeout +stuntman-client` (coreutils-timeout is runtime-only). Git source — SDK clones `muink/stunserver.git` directly. `stuntman/compile` builds the client/server/testcode splits.
- **nikki bridge**: the nikki stack (`mihomo-alpha` + `nikki` + `luci-app-nikki` + `luci-i18n-nikki-zh-hans`) comes from a **pinned src-git feed** (`BRIDGE_*` in `tooling/build-plan.sh`) pointing at `2017fighting/OpenWrt-nikki`; the Makefiles live only there (upgrade = bump `BRIDGE_REF`). `mihomo-alpha` builds from the personal mihomo fork (`2017fighting/mihomo`, commit-pinned, `GOAMD64=v3` on x86_64 — its smoke test greps the `alpha-fork-` version string out of the binary). The SDK bins bridge apks into `bin/packages/<arch>/nikki/`; cmd_compile relocates them into this feed's dir so ONE signed `packages.adb` covers everything.
- **golang corelib**: mihomo-alpha needs `PKG_BUILD_DEPENDS:=golang/host` and hard-includes `$(TOPDIR)/feeds/packages/lang/golang/golang-package.mk`. `golang` is borrowed from the packages repo like boost (SDK-pinned ref, sparse `lang/golang`) and lands at `lang/golang` in THIS feed; cmd_install additionally symlinks it to `feeds/packages/lang/golang` in the SDK so the hard include resolves without registering the packages feed.
- **SDK build limitations** (key for adding packages): the OpenWrt SDK ships **no core package sources** and only generates compile rules for **feed packages** (`package/feeds/*`), not ad-hoc `package/libs/` additions; the direct-compile graph force-builds every `DEPENDS` that resolves to a registered feed. All resulting CI workarounds are owned by **`tooling/build-plan.sh`** (the *build plan* module; `plan` dry-run prints the whole derivation, and `tooling/tests/` asserts it against the Makefiles):
  - **Runtime-only deps**: standard packages the device already has (`curl`/`bash`/`coreutils-timeout`) are declared in `DEPENDS` but kept OUT of any registered feed — the plan registers `luci` + `base` (the openwrt main repo itself, needed for the +luci-base closure of luci.mk apps: rpcd/ucode/libnl-tiny/lua/...), NOT `packages`. OpenWrt then records them in the apk's `Depends:` without building them (proven by `jsonfilter`, which is core and behaves this way naturally); the device auto-installs them from its own repos. Force-built base/luci-feed apks land in `bin/packages/<arch>/{base,luci}/` — outside this feed's published dir, same as kmods.
  - **Core libs we must build**: `boost` (stuntman's `PKG_BUILD_DEPENDS:=boost/host`), `openssl` (stuntman's `+libopenssl`) and `golang` (the nikki bridge's `golang/host`; see above) are sparse-checked into THIS feed at CI time by the plan's `corelibs` step (`libs/boost` from `openwrt/packages` at the SDK-pinned ref + `lang/python/python3-version.mk`, `libs/openssl` from `openwrt@<version>`, `lang/golang` from `openwrt/packages` at the SDK-pinned ref) so `feeds update` indexes them and dependents build them; openssl builds with `CONFIG_OPENSSL_ENGINE=n` (devcrypto needs `cryptodev.h`, absent in SDK). The resulting apks ship in this feed (redundant with the device's core, same version).
  - For a source package with split sub-packages, build the SOURCE (`<pkg>/compile`), not individual splits — the plan's install list and compile order already do this.
- apk EC signing keypair (openssl prime256v1) is permanent — rotating it is a breaking change for every installed device. apk embeds the index signature in `packages.adb` via `apk adbsign --sign-key` (no separate `.sig`).
