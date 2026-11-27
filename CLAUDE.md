# openwrt-feeds

Self-built OpenWrt **source feed** (package Makefiles) + a GitHub Actions pipeline
that compiles, signs, and publishes a **binary apk feed** to GitHub Pages.

`punchd` is the only package (`docs/adr/0002`); everything else the router needs
comes from OpenWrt's own feeds — `natmap` is pulled in as a runtime dependency.

## Build / test

- There is **no local build**. Compilation runs in CI via the OpenWrt SDK
  (`.github/workflows/build.yml`). Push to `main` or `workflow_dispatch` triggers it.
- OpenWrt **25.12.4 is APK-based** (`.apk` + `packages.adb`). Only the index is signed.
- Host-side tests (no SDK needed): `sh tooling/tests/run.sh` — the build-plan
  derivation asserted against this repo's Makefiles; CI runs it in a fast
  `Host tests` job before the matrix build.

## Local helpers

- `sh tooling/gen-key.sh`            # one-time openssl EC apk signing keypair (privkey -> secret APK_SIGN_KEY)
- `sh tooling/make-index.sh site`    # regenerate Pages index.html (optional `SITE_BASE=...`)
- `sh tooling/build-plan.sh plan`    # dry-run print of everything CI will build (derived from the Makefiles)

## Layout / conventions

- `net/punchd/Makefile`     — the only apk package definition (the source feed)
- `feeds.config`           — JSON; drives the build matrix (`openwrt_version` x `arch`). Edit here to add an arch.
- `keys/2017fighting.pem` — apk signing public key (EC PEM `-----BEGIN PUBLIC KEY-----`, committed); the private key is the `APK_SIGN_KEY` secret
- `.github/workflows/`     — `build.yml` (build+sign+deploy), `keygen.yml` (one-time keypair)
- Adding a package: drop `net/<pkg>/Makefile` at the repo root; push. (`tooling/build-plan.sh` scans `net/`; a `luci/` app would also need the `luci` feed re-registered in `cmd_register` — `docs/adr/0002` removed the last one.)
- Adding an arch: append to `feeds.config` (the workflow reads it via `jq`).
- `feed.sh`              — on-device installer (adds apk key + feed, runs `apk update`); copied to the Pages site root by `build.yml`.

## Notes

- In CI: run `make defconfig` before package compile (no TTY); pre-fetch the source into `dl/`.
- `PKGARCH` auto-detects the SDK target arch.
- **SDK build limitations** (key for adding packages): the OpenWrt SDK ships **no core package sources** and only generates compile rules for **feed packages** (`package/feeds/*`), not ad-hoc `package/libs/` additions; the direct-compile graph force-builds every `DEPENDS` that resolves to a registered feed. All resulting CI workarounds are owned by **`tooling/build-plan.sh`** (the *build plan* module; `plan` dry-run prints the whole derivation, and `tooling/tests/` asserts it against the Makefiles):
  - **Runtime-only deps**: standard packages the device already has (`natmap`, `ca-bundle`) are declared in `DEPENDS` but kept OUT of any registered feed — the plan registers `base` only (`luci` used to be needed for `luci-app-natmapt`; `packages` was never registered). OpenWrt then records them in the apk's `Depends:` without building them, and the device auto-installs them from its own repos.
  - **Core libs we must build**: `golang` (punchd's `PKG_BUILD_DEPENDS:=golang/host` and hard include) is sparse-checked into THIS feed at CI time by the plan's `corelibs` step (`lang/golang` from `openwrt/packages` at the SDK-pinned ref) so `feeds update` indexes it and punchd builds against it. `cmd_install` symlinks it to `feeds/packages/lang/golang` in the SDK so the hard include resolves without registering the packages feed. There is no other corelib any more (boost/openssl left with stuntman, `docs/adr/0002`).
- **punchd** (`net/punchd/`): the router-side agent of the declared CGNAT punch (home-ops `docs/adr/0044`), Go binary from `2017fighting/punch` **pinned by commit** — `PKG_SOURCE_VERSION` = `47d6c08…`, the commit `v0.2.2` points at (never a tag or a branch; `v0.1.0` moved it off `2e56c87` because the `LICENSE` only exists from that commit and `PKG_LICENSE_FILES` has to name a real file); `PKG_VERSION` is that commit's date, `PKG_RELEASE:=1` (a new date resets it — only a same-day re-pin has to bump it), and like every git source here there is deliberately no `PKG_MIRROR_HASH`. `PKG_BUILD_VERSION` (`2026.11.27-47d6c08`) reaches the binary through `GO_PKG_LDFLAGS_X:=main.version=…`, so `punchd -version` names the release and the compile smoke greps that string (it is literal, not a `$(…)` expression, because the build plan reads it with `sed`). `GO_PKG_BUILD_PKG` builds only `cmd/punchd`, so the controller half (client-go) never enters the router binary, and `GO_AMD64:=v1` protects old x86_64 CPUs (J1900/N5105). Installs `/usr/bin/punchd`, `/etc/init.d/punchd`, `/etc/punch/punch.conf` (conffile) and `/etc/punch/token.example`; `/etc/punch` is `0700` and **no token is ever packaged** (the token is device-local, which is why the package never enables itself — the operator does, after placing it). `DEPENDS:=+natmap +ca-bundle +firewall4`:
  - `natmap` — the only external program punchd execs (`natmap.go` runs one child per punch). Official `openwrt/packages` package, so the dep is runtime-only (see above). `natmapt`/`natmap` own the same files, so old devices must `apk del natmapt` first (`docs/adr/0002`).
  - `ca-bundle` — Go's TLS to `https://punch.raenzo.com` reads `/etc/ssl/certs` from it.
  - `firewall4` — `nft.go` execs `nft` and `Preflight` reads fw4's `auto_includes`; base is registered, so CI really builds firewall4 (and its nftables splits) to keep the apk's `Depends:` truthful.
  The postinst only wires `/etc/punch/` into `/etc/sysupgrade.conf` (the token must survive an upgrade); it does not enable the service.
