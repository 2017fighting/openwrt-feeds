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
- `natmapt` is a **C binary** (upstream <https://github.com/heiher/natmap>), compiled with the SDK's musl/gcc toolchain — unlike mosdns, it is *not* pure Go and exercises the real target toolchain. Its release tarball (`natmap-<ver>.tar.xz`) is pre-fetched into `dl/`. It `DEPENDS` on `+curl +jsonfilter +bash`; `luci-app-natmapt` depends on `+natmapt +coreutils-timeout` — those live in the OpenWrt **`packages`** feed, which `build.yml` registers alongside `luci` (why CI clones it). `natmapt`'s single Makefile also defines 5 `PKGARCH:=all` client/notify script sub-packages.
- `stuntman-client` (in `net/stuntman/`, vendored from <https://github.com/muink/openwrt-stuntman>) provides the `stunclient` binary that `luci-app-natmapt`'s NAT-type test depends on (`+stuntman-client`). C++ target binary built with the SDK toolchain; its `PKG_BUILD_DEPENDS:=boost/host` makes CI build host **boost** first (heavier — only the `-client` split is built, not server/testcode). Source is `PKG_SOURCE_PROTO:=git`, cloned directly from `muink/stunserver.git` by the SDK — no `dl/` pre-fetch (unlike the tarball packages).
- apk EC signing keypair (openssl prime256v1) is permanent — rotating it is a breaking change for every installed device. apk embeds the index signature in `packages.adb` via `apk adbsign --sign-key` (no separate `.sig`).
