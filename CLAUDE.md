# openwrt-feeds

Self-built OpenWrt **source feed** (package Makefiles) + a GitHub Actions pipeline
that compiles, signs, and publishes a **binary apk feed** to GitHub Pages.

## Build / test
- There is **no local build**. Compilation runs in CI via the OpenWrt SDK
  (`.github/workflows/build.yml`). Push to `main` or `workflow_dispatch` triggers it.
- OpenWrt **25.12.4 is APK-based** (`.apk` + `packages.adb`). Only the index is signed.

## Local helpers
- `sh tooling/gen-key.sh`            # one-time openssl EC apk signing keypair (privkey -> secret APK_SIGN_KEY)
- `sh tooling/make-index.sh site`    # regenerate Pages index.html (optional `SITE_BASE=...`)

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
- `natmapt` status interface: `natmap-update.sh` (the natmap `-e` hook; `/etc/init.d/natmap` exports `SECTIONID`/`COMMENT`/`STATUS_NAME` into it) writes two JSONs per mapping event — private `/var/run/natmap/$PPID.json` (keyed by PID; matched & cleaned by the init's `clear_status_files`) and public `/www/natmap/<name|SECTIONID>.json` (served by uhttpd over HTTP as a query interface for other programs). Both carry `sid,comment,ip,port,ip4p,inner_port,protocol,inner_ip`; the public one adds `name,pid`. Optional `name` UCI option → `STATUS_NAME` → a stable, readable URL (`/www/natmap/hath.json`), falling back to `SECTIONID` (the anonymous `cfgXXXXXX`, which shifts when sections are reordered). The filename is sanitized (unsafe chars → `_`, leading `[._-]` stripped: path-traversal-safe, and non-hidden so the glob-based cleanup still matches it). Writes are atomic via `_status_write` (temp + rename); `clear_status_files`/`_clear_status_dir <dir> [sid]` cleans both dirs (per-sid by the `.sid` field inside the JSON, clear-all via `find`).
- `stuntman-client` (`net/stuntman/`, vendored from <https://github.com/muink/openwrt-stuntman>) provides `stunclient` for `luci-app-natmapt`'s NAT-type test. C++ target binary; `PKG_BUILD_DEPENDS:=boost/host` (heavier host-boost build); `+libopenssl` (both pulled into THIS feed at CI time — see below). `luci-app-natmapt` depends on `+natmapt +coreutils-timeout +stuntman-client` (coreutils-timeout is runtime-only). Git source — SDK clones `muink/stunserver.git` directly. `stuntman/compile` builds the client/server/testcode splits.
- **SDK build limitations** (key for adding packages): the OpenWrt SDK ships **no core package sources** (openssl/ncurses/readline/boost-target/…) and its `staging_dir` lacks them, so it **cannot** build any package needing a core lib. It also only generates compile rules for **feed packages** (`package/feeds/*`), not ad-hoc `package/libs/` additions; and the direct-compile graph force-builds every `DEPENDS` that resolves to a registered feed. Two patterns are used here:
  - **Runtime-only deps**: standard packages the device already has (`curl`/`bash`/`jsonfilter`/`coreutils-timeout`) are declared in `DEPENDS` but kept OUT of any registered feed — `build.yml` registers `luci` only, NOT `packages`. OpenWrt then records them in the apk's `Depends:` without building them (proven by `jsonfilter`, which is core and behaves this way naturally); the device auto-installs them from its own repos.
  - **Core libs we must build**: `boost` (stuntman's `PKG_BUILD_DEPENDS:=boost/host`) and `openssl` (stuntman's `+libopenssl`) are sparse-checked into THIS feed at CI time (`libs/boost` from `openwrt/packages` at the SDK's pinned ref, `libs/openssl` from `openwrt@<version>`) so `feeds update` indexes them and stuntman builds them. openssl is built with `CONFIG_OPENSSL_ENGINE=n` (the devcrypto engine needs `cryptodev.h`, absent in SDK). The resulting boost/openssl apks ship in this feed (redundant with the device's core, same version).
  - For a source package with split sub-packages, build the SOURCE (`<pkg>/compile`), not individual splits.
- apk EC signing keypair (openssl prime256v1) is permanent — rotating it is a breaking change for every installed device. apk embeds the index signature in `packages.adb` via `apk adbsign --sign-key` (no separate `.sig`).
